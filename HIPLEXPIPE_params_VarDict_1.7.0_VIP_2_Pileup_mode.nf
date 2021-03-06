#!/usr/bin/env nextflow

// Required Inputs
refFolder      = file("/projects/vh83/reference/genomes/b37/bwa_0.7.12_index/")
inputDirectory = file('./bams')
tmp_dir        = file('/scratch/vh83/tmp/')

//project specific bed files

params.vardictBed       = ""
params.intervalFile     = ""
params.restrictedBed    = ""

// Getting Reference Files
refBase          = "$refFolder/human_g1k_v37_decoy"
ref              = file("${refBase}.fasta")
refDict          = file("${refBase}.dict")
refFai           = file("${refBase}.fasta.fai")
millsIndels      = file("${refFolder}/accessory_files/Mills_and_1000G_gold_standard.indels.b37.vcf")
dbSNP            = file("${refFolder}/accessory_files/dbsnp_138.b37.vcf")
genome_file      = file("/projects/vh83/reference/genomes/b37/accessory_files/human_g1k_v37_decoy_GenomeFile.txt")
header           = file("/projects/vh83/local_software/vardict/vcf_contig_header_lines.txt")
af_thr           = 0.1
rheader          = file("/projects/vh83/pipelines/code/Rheader.txt")

//Annotation resources
dbsnp_b37       = file("/projects/vh83/reference/genomes/b37/accessory_files/dbsnp_138.b37.vcf")
other_vep       = file("/usr/local/vep/90/ensembl-vep/cache")
vep_brcaex      = file("/projects/vh83/reference/annotation_databases/BRCA-Exchange/BRCA-exchange_accessed-180118/BRCA-exchange_accessed-180118.sort.vcf.gz")
vep_gnomad      = file("/projects/vh83/reference/annotation_databases/gnomAD/gnomad.exomes.r2.0.2.sites/gnomad.exomes.r2.0.2.sites.vcf.gz")
vep_revel       = file("/projects/vh83/reference/annotation_databases/REVEL/REVEL-030616/revel_all_chromosomes.vcf.gz")
vep_maxentscan  = file("/projects/vh83/reference/annotation_databases/MaxEntScan/MaxEntScan_accessed-240118")
vep_exac        = file("/projects/vh83/reference/annotation_databases/ExAC/ExAC_nonTCGA.r0.3.1/ExAC_nonTCGA.r0.3.1.sites.vep.vcf.gz")
vep_dbnsfp      = file("/projects/vh83/reference/annotation_databases/dbNSFP/dbNSFPv2.9.3-VEP/dbNSFP-2.9.3.gz")
vep_dbscsnv     = file("/projects/vh83/reference/annotation_databases/dbscSNV/dbscSNV1.0-VEP/dbscSNV.txt.gz")
vep_cadd        = file("/projects/vh83/reference/annotation_databases/CADD/CADD-v1.3/1000G_phase3.tsv.gz")

// Tools
picardJar      = '~/picard.jar'
bwaModule      = 'bwa/0.7.17-gcc5'
samtoolsModule = 'samtools/1.9'


// Creating channel from input directory
ch_inputFiles = Channel.fromFilePairs("$inputDirectory/*.{bam,bam.bai}", flat: true)

ch_inputFiles.into{ch_mappedBam1;ch_mappedBam2;ch_mappedBam3;ch_mappedBam4;ch_mappedBam5;ch_mappedBam6}


process run_vardict {

    label 'vardict_small'

    input:
        set baseName, file(bam), file(bai) from ch_mappedBam1               
    output: 
        set baseName, file("${baseName}.tsv") into ch_vardictTSV           
    
    publishDir path: './variants_raw_out', mode: 'copy'                                    
    
    """
    export PATH=/projects/vh83/local_software/vardict/VarDictJava/build/install/VarDict/bin/:$PATH
    VarDict -G ${ref} -f 0.1 -N "${baseName}" --nosv -p -b ${bam} -c 1 -S 2 -E 3 -g 4 ${params.intervalFile} > "${baseName}.tsv"
    """
}

process makeVCF {

    label 'vardict_small'

    input:
        set baseName, file(tsv) from ch_vardictTSV
    output:
        set baseName, file("${baseName}.vardict.vcf") into ch_vardictVCFs
    
    publishDir path: './variants_raw_out', mode: 'copy'
    
    script:

    """
    module purge
    module load R/3.5.1
    cat ${tsv} | /projects/vh83/local_software/vardict/VarDict-1.7.0/bin/teststrandbias.R | \
        /projects/vh83/local_software/vardict/VarDict-1.7.0/bin/var2vcf_valid.pl -N "${baseName}" \
        -f 0.1 -E > "${baseName}.vardict.vcf"
    """
}

process reheaderVCF {

    label 'genomics_1'

    input:
        set baseName, file(vcf) from ch_vardictVCFs
    
    output:
        set baseName, file("${baseName}.reheader.vcf.gz") into ch_reheaderVCF

    publishDir path: './variants_raw_out', mode: 'copy'                                    
    
    module     'bcftools/1.8'

    script:
    """
    bcftools annotate -h ${header} -O z -o "${baseName}.reheader.vcf.gz" ${vcf}
    """

}

process sortVCFS {

    label 'genomics_1'

    input:
        set baseName, file(vcf) from ch_reheaderVCF
    output:
        set baseName, file("${baseName}.sorted.vcf.gz") into ch_sortedVCF

    publishDir path: './variants_raw_out', mode: 'copy'                                    
    
    module     'bcftools/1.8'

    script:
    """
    bcftools sort -o "${baseName}.sorted.vcf.gz" -O z ${vcf}
    """
}

process indexVCFS {

    label 'genomics_1'

    input:
        set baseName, file(vcf) from ch_sortedVCF
    output:
        set baseName, file(vcf), file("${baseName}.sorted.vcf.gz.tbi") into ch_indexedVCF

    publishDir path: './variants_raw_out', mode: 'copy'                                    
    
    module     'bcftools/1.8'

    script:
    """
    bcftools index -f --tbi ${vcf} -o ${baseName}.sorted.vcf.gz.tbi
    """
}

//duplicate ch_indexedVCF
ch_indexedVCF.into{ch_list;ch_files}
//set one version to a list of filenames of the VCF
ch_list.map {it -> it[1].name}
    .collectFile(name: 'list2.txt', newLine: true)
    .set {ch_list_f}
//set the second to all the files
ch_files
    .collect()
    .set {ch_all_files}

//feed both to the merge so that the indexes are available to bcftools

process mergeVCFS {

    label 'medium_6h'

    echo true

    publishDir './variants_merged/', mode: 'copy'

    input:
    file list from ch_list_f
    file '*' from ch_all_files
    
    output:
    file "final_merge.vardict.vcf.gz" into ch_mergedfinalVCF

    module     'bcftools/1.8'
    
    script: 
    
    """
    split -l 500 list2.txt temp_shorter_list_
    for i in temp_shorter_*; do bcftools merge -m none --gvcf ${ref} -l \$i -O z -o \$i.merged.vcf.gz; bcftools index -t \$i.merged.vcf.gz; done
    ls *merged.vcf.gz > list3.txt
    bcftools merge -m none -O z -o "final_merge.vardict.vcf.gz" -l list3.txt
    """
}

process vt_decompose_normalise {

    label 'medium_6h'
        
    input:
        file(vcf) from ch_mergedfinalVCF
    output:
        file("merged.vardict.vt.vcf.gz") into ch_vtDecomposeVCF

    publishDir path: './variants_merged', mode: 'copy'

    module      'vt/0.57'

    script:
    """
    vt decompose -s $vcf | vt normalize -n -r $ref -o merged.vardict.vt.vcf.gz -
    """
}

process apply_vep {

    label 'vep'

    input:
        file(vcf) from ch_vtDecomposeVCF
    output:
        file("merged.vardict.vt.vep.vcf") into ch_vepVCF

    publishDir path: './variants_merged', mode: 'copy'

    module      'vep/90'

    script:
    """
    vep --cache --dir_cache $other_vep \
                      --assembly GRCh37 --refseq --offline \
                      --fasta $ref \
                      --sift b --polyphen b --symbol --numbers --biotype \
                      --total_length --hgvs --format vcf \
                      --vcf --force_overwrite --flag_pick --no_stats \
                      --fork ${task.cpus} \
                      -i ${vcf} \
                      -o merged.vardict.vt.vep.vcf
    """
}
    



