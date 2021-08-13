
#previous_stage defined but never used, commenting out for now
#only determines pangolin lineage for sequences which pass filters
#AND
#don't already have a pangolin lineage
#but might we want to allow for lineage re-assignment?
rule redcap_normal_pangolin:
    input:
#        previous_stage = config["output_path"] + "/logs/1_summarize_preprocess_uk.log",
        fasta = rules.redcap_add_dups_to_lineageless.output.fasta
    params:
        outdir = config["output_path"] + "/2/normal_pangolin",
        tmpdir = config["output_path"] + "/2/normal_pangolin/tmp"
    output:
        lineages = config["output_path"] + "/2/normal_pangolin/lineage_report.csv"
    log:
        config["output_path"] + "/logs/2_redcap_normal_pangolin.log"
    shell:
        """
        pangolin {input.fasta} \
        --outdir {params.outdir} \
        --tempdir {params.tmpdir}  >> {log} 2>&1
        """


rule redcap_filter_unassignable_lineage:
    input:
        lineages = rules.redcap_normal_pangolin.output.lineages
    output:
        lineages = config["output_path"] + "/2/normal_pangolin/lineage_report_filtered.csv"
    log:
        config["output_path"] + "/logs/2_redcap_filter_unassignable_lineage.log"
    run:
        import pandas as pd

        df = pd.read_csv(input.lineages)

        df_filtered = df.loc[df['lineage'].notnull()]
        df_unassigned = df.loc[df['lineage'].isnull()]

        df_filtered.to_csv(output.lineages, index=False)

        with open(str(log), "w") as log_out:
            log_out.write("The following sequences were not assigned a pangolin lineage: \n")
            [log_out.write(i + "\n") for i in df_unassigned['taxon']]
        log_out.close()


#index column should be strain
#originally took rules.uk_add_previous_lineages_to_metadata.output.metadata from rule_1
#will append new lineages to pango column
rule redcap_add_pangolin_lineages_to_metadata:
    input:
        metadata = rules.redcap_add_del_finder_result_to_metadata.output.metadata,
        lineages = rules.filter_unassignable_lineage.output.lineages
    output:
        metadata = config["output_path"] + "/2/redcap.with_new_lineages.csv"
    log:
        config["output_path"] + "/logs/2_redcap_add_normal_pangolin_lineages_to_metadata.log"
    shell:
        """
        fastafunk add_columns \
          --in-metadata {input.metadata} \
          --in-data {input.lineages} \
          --index-column strain \
          --join-on taxon \
          --new-columns pango lineage_support pango_version \
          --where-column pango=lineage lineage_support=probability pango_version=pangoLEARN_version \
          --out-metadata {output.metadata} &>> {log}
        """


#currently, no lineage reassignment will occur
#maybe check which columns are actually needed
rule get_filled_analysis_instrument:
    input:
        metadata = rules.redcap_add_pangolin_lineages_to_metadata.output.metadata
    output:
        metadata = config["output_path"] + "/2/filled_analysis_instrument.csv"
    run:
        import pandas as pd

        df = pd.read_csv(input.metadata)

        df.loc[:,'sequence_length'] = df.loc[:,'length']
        df.loc[:, 'gaps'] = df.loc[:, 'missing']
        df.loc[:, 'missing'] = df.loc[:, 'coverage']

        df = df.loc[:,['central_id', 'redcap_repeat_instance', \
                        'consensus', 'ave_depth', 'sequence_length', \
                        'missing', 'gaps', 'pango', 'lineage_support', 'pango_version', \
                        'ph_cluster', 'p323l', 'd614g', 'n439k', \
                        'del_1605_3', 'epi_week', 'analysis_complete']]

        df.to_csv(output.metadata, index=False)


#would be more appropriate to move this and previous rule to later stage, when ph_cluster/ph_lineage would be filled in
rule import_analysis_instrument_to_redcap:
    input:
        metadata = rules.get_filled_analysis_instrument.output.metadata,
        redcap_db = config["redcap_access"]
    output:
        metadata = config["output_path"] + "/2/analysis_intrument_form_exported.csv"
    run:
        import redcap
        import pandas as pd

        with open(input.redcap_db, 'r') as f:
            read_file = f.read().strip('\n')
            url = read_file.split(',')[0]
            key = read_file.split(',')[1]
        f.close()

        proj = redcap.Project(url, key)
        df = pd.read_csv(input.metadata)
        df.insert(1, 'redcap_repeat_instrument', 'Analysis')
        df.loc[:,'redcap_repeat_instrument'] = df.loc[:,'redcap_repeat_instrument'].str.casefold()
        df.loc[:,'analysis_complete'] = df.loc[:,'analysis_complete'].map(dict(Complete=1, Incomplete=0))

        #convert missing column to percentage
        df.loc[:,'missing'] = df.loc[:,'missing'].apply(lambda x:round(x*100,2))

        proj.import_records(df)
        df.to_csv(output.metadata, index=False)


#rename pango back to lineage
#uk_lineage/ph_cluster will be empty?
#need to use pandas to rename index column
#as the fetch command doesn't seem to support that
rule redcap_output_lineage_table:
    input:
        fasta = rules.redcap_filter_omitted_sequences.output.fasta,
        metadata = rules.redcap_add_pangolin_lineages_to_metadata.output.metadata
    params:
        country_code = config["country_code"]
    output:
        fasta = config["output_path"] + "/2/redcap.matched.fasta",
        metadata = config["output_path"] + "/2/redcap.matched.lineages.csv"
    log:
        config["output_path"] + "/logs/2_redcap_output_full_lineage_table.log"
    shell:
        """
        fastafunk fetch \
        --in-fasta {input.fasta} \
        --in-metadata {input.metadata} \
        --index-column strain \
        --filter-column strain country adm1 adm2 \
                        sample_date epi_week \
                        lineage {params.country_code}_lineage \
        --where-column country=adm0 lineage=pango\
        --out-fasta {output.fasta} \
        --out-metadata {output.metadata} \
        --log-file {log} \
        --low-memory \
        --restrict
         """


#strain is the gisaid equivalent to fasta_header
#will be necessary for combine step
#rule rename_fasta_header_to_strain:
#    input:
#        metadata = rules.uk_output_lineage_table.output.metadata
#    output:
#        metadata = config["output_path"] + "/2/RC_metadata.lineages.strain.csv"
#    run:
#        import pandas as pd
#
#        df = pd.read_csv(input.metadata)
#
#        df.rename(columns={'fasta_header':'strain'}, inplace=True)
#
#        df.to_csv(output.metadata, index=False)


#commented out as it doesn't seem immediately useful
#had to include 'analysis_form' input to upload to redcap
#there's probably a better way of doing that
rule summarize_pangolin_lineage_typing:
    input:
        fasta = rules.redcap_output_lineage_table.output.fasta,
        metadata = rules.redcap_output_lineage_table.output.metadata,
        analysis_form = rules.import_analysis_instrument_to_redcap.output.metadata
    params:
        grapevine_webhook = config["grapevine_webhook"],
        json_path = config["json_path"],
        date = config["date"]
    log:
        config["output_path"] + "/logs/2_summarize_pangolin_lineage_typing.log"
#    shell:
#        """
#        echo '{{"text":"' > {params.json_path}/2_data.json
#        echo "*Step 2: {params.date} COG-UK pangolin typing complete*\\n" >> {params.json_path}/2_data.json
#        echo '"}}' >> {params.json_path}/2_data.json
#        echo "webhook {params.grapevine_webhook}"
#        curl -X POST -H "Content-type: application/json" -d @{params.json_path}/2_data.json {params.grapevine_webhook}
#        """
