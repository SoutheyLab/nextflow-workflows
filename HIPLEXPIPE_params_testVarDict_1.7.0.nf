#!/usr/bin/env nextflow

// Required Inputs
refFolder      = file("/projects/vh83/reference/genomes/b37/bwa_0.7.12_index/")
inputDirectory = file('./fastqs')
tmp_dir        = file('/scratch/vh83/tmp/')

//project specific bed files

params.vardictBed       = ""
params.intervalFile     = ""
params.restrictedBed    = ""
params.primer_bedpe_file= ""

// Getting Reference Files
refBase          = "$refFolder/human_g1k_v37_decoy"
ref              = file("${refBase}.fasta")
refDict          = file("${refBase}.dict")
refFai           = file("${refBase}.fasta.fai")
millsIndels      = file("${refFolder}/accessory_files/Mills_and_1000G_gold_standard.indels.b37.vcf")
dbSNP            = file("${refFolder}/accessory_files/dbsnp_138.b37.vcf")
genome_file      = file("/projects/vh83/reference/genomes/b37/accessory_files/human_g1k_v37_decoy_GenomeFile.txt")
header           = file("/home/jste0021/vh83/reference/genomes/b37/vcf_contig_header_lines.txt")
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
bamclipper_exe = '/projects/vh83/local_software/bamclipper/bamclipper.sh'


// Creating channel from input directory
ch_inputFiles = Channel.fromFilePairs("${inputDirectory}/*_R{1,2}_001.fastq.gz")


process align_bwa {

    label 'bwa_small'

    input:
        set baseName, file(fastqs) from ch_inputFiles
    output:
        set baseName, file("${baseName}.hq.sorted.bam"), file("${baseName}.hq.sorted.bam.bai") into ch_mappedBams

    publishDir path: './bam_out', mode: 'copy'

    module      bwaModule
    module      samtoolsModule

    """
    bwa mem -M -t ${task.cpus} -R "@RG\\tID:${baseName}\\tSM:${baseName}\\tPU:lib1\\tPL:Illumina" $ref ${fastqs[0]} ${fastqs[1]}  \
        | samtools view -u -h -q 1 -f 2 -F 4 -F 8 -F 256 - \
        | samtools sort -@ ${task.cpus} -o "${baseName}.hq.sorted.bam"
    samtools index "${baseName}.hq.sorted.bam" "${baseName}.hq.sorted.bam.bai"
    """
}

ch_mappedBams.into{ch_mappedBam1;ch_mappedBam2;ch_mappedBam3;ch_mappedBam4;ch_mappedBam5;ch_mappedBam6;ch_forBamClipper}

process run_bamClipper {

    label 'bwa_small'

    input:
        set baseName, file(bam), file(bai) from ch_forBamClipper               
    output: 
        set baseName, file("${baseName}.hq.sorted.primerclipped.bam"), file("${baseName}.hq.sorted.primerclipped.bam.bai") into ch_forperBase           
    
    publishDir path: './bamclipper', mode: 'copy'                                    
    
    module      'gnuparallel/20190122'
    module      'samtools/1.9'

    """
    ${bamclipper_exe} -b ${bam} -p ${params.primer_bedpe_file} -n ${task.cpus}
    """
}

//***magic sample collection right here generate list.txt***
ch_forperBase.into{ch_bamList;ch_bams}

//set one version to a list of filenames of the VCF

ch_bamList.map { it -> it[1].name }
       .collectFile(name: 'list.txt', newLine: true)
       .set {ch_bamList_f}

//set the second to all the files

ch_bams
    .collect()
    .set {ch_all_bams}

//awk 'BEGIN{FS=OFS="\t"}{if($0 ~ /^#/)next;call=0; nocall=0;for(i=10; i<=NF; i++)if($i ~ /^\.\/\.:/)nocall++;else call++;print $1, $2, $4, $5, call, nocall}'

process generatePerbaseMetrics {

    label 'medium_6h'

    input:
        file list from ch_bamList_f
        file '*' from ch_all_bams               
    output: 
        file("mpileup.vcf.gz") into ch_mpileupOUT           
    
    //publishDir path: './bamclipper', mode: 'copy'                                    
    
    
    module      'samtools/1.9'
    module      'bcftools/1.8'

    """
    bcftools mpileup --threads ${task.cpus} -Oz -d 250 -B -R ${params.restrictedBed} -a "FORMAT/DP" -f ${ref} -b list.txt -o mpileup.vcf.gz

    """
//| bcftools call --threads ${task.cpus} -Oz -m -o mpileup_out.vcf.gz 
}

process sortpileupVCFS {

    label 'small_1'

    input:
        file(vcf) from ch_mpileupOUT
    output:
        file("mpileup.sorted.vcf.gz") into ch_mpileupsortedVCF

    publishDir path: './variants_raw_out', mode: 'copy'                                    
    
    module     'bcftools/1.8'

    script:
    """
    bcftools sort -o "mpileup.sorted.vcf.gz" -O z ${vcf}
    """
}

process indexpileupVCFS {

    label 'small_1'

    input:
        file(vcf) from ch_mpileupsortedVCF
    output:
        set file(vcf), file("*.tbi") into ch_indexedmpileupVCF

    publishDir path: './variants_raw_out', mode: 'copy'                                    
    
    module     'bcftools/1.8'

    script:
    """
    bcftools index -f --tbi ${vcf} -o ${vcf}.tbi
    """
}


process run_vardict {

    label 'vardict_small'

    input:
        set baseName, file(bam), file(bai) from ch_mappedBam1               
    output: 
        set baseName, file("${baseName}.tsv") into ch_vardictTSV           
    
    publishDir path: './variants_raw_out', mode: 'copy'                                    
    
    """
    export PATH=/home/jste0021/scripts/VarDict-1.7.0/bin/:$PATH
    VarDict -G ${ref} -f 0.1 -N "${baseName}" --nosv -b ${bam} -c 1 -S 2 -E 3 -g 4 ${params.vardictBed} > "${baseName}.tsv"
    """
}

process makeVCF {

    label 'medium_6h'

    input:
        set baseName, file(tsv) from ch_vardictTSV
    output:
        set baseName, file("${baseName}.vardict.vcf") into ch_vardictVCFs
    
    publishDir path: './variants_raw_out', mode: 'copy'
    
    script:

    """
    module purge
    module load R/3.5.1
    cat ${tsv} | /home/jste0021/scripts/VarDict-1.7.0/bin/teststrandbias.R | \
        /home/jste0021/scripts/VarDict-1.7.0/bin/var2vcf_valid.pl -N "${baseName}" \
        -f 0.1 -E > "${baseName}.vardict.vcf"
    """
}

process reheaderVCF {

    label 'small_1'

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

    label 'small_1'

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

    label 'small_1'

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

    label 'small_1'

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
    for i in temp_shorter_*; do bcftools merge -m none -l \$i -O z -o \$i.merged.vcf.gz; bcftools index \$i.merged.vcf.gz; done
    ls *merged.vcf.gz > list3.txt
    bcftools merge -R ${params.restrictedBed} -m none -O z -o "final_merge.vardict.vcf.gz" -l list3.txt
    """
}

process vt_decompose_normalise {

    label 'small_1'
        
    input:
        file(vcf) from ch_mergedfinalVCF
    output:
        file("merged.vardict.vt.vcf.gz") into ch_vtDecomposeVCF

    publishDir path: './variants_merged', mode: 'copy'

    module      'vt'

    script:
    """
    vt decompose -s $vcf | vt normalize -r $ref -o merged.vardict.vt.vcf.gz -
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
                      --custom $vep_brcaex,brcaex,vcf,exact,0,Clinical_significance_ENIGMA,Comment_on_clinical_significance_ENIGMA,Date_last_evaluated_ENIGMA,Pathogenicity_expert,HGVS_cDNA,HGVS_Protein,BIC_Nomenclature \
                      --custom $vep_gnomad,gnomAD,vcf,exact,0,AF_NFE,AN_NFE \
                      --custom $vep_revel,RVL,vcf,exact,0,REVEL_SCORE \
                      --plugin MaxEntScan,$vep_maxentscan \
                      --plugin ExAC,$vep_exac,AC,AN \
                      --plugin dbNSFP,$vep_dbnsfp,REVEL_score,REVEL_rankscore \
                      --plugin dbscSNV,$vep_dbscsnv \
                      --plugin CADD,$vep_cadd \
                      --fork ${task.cpus} \
                      -i ${vcf} \
                      -o merged.vardict.vt.vep.vcf
    """
}
    

/*
Stats Generation Section
*/

process AmpliconMetircs {

    label 'medium_1h'

    input:
        set sample, file(bam), file(bai) from ch_mappedBam6
    output:
        file("${sample}.amplicon.out") into ch_AmpliconMetrics
    

    script:
    """
    module load bedtools/2.27.1-gcc5
    bedtools coverage -f 5E-1 -a $params.restrictedBed -b $bam | sed "s/\$/\t$sample/" > ${sample}.amplicon.out 
    """
}

ch_AmpliconMetrics.collect().set{ch_catAmp}

process catAmplicons {

    label 'medium_1h'

    publishDir path: './metrics/', mode: 'copy'

    input:
        file(amplicon) from ch_catAmp
    output:
        file("amplicon.stats.tsv")

    script:

    """
    cat ${amplicon} > "amplicon.stats.tsv"
    """
}


process InstersectBed {

    label 'small_1'

    input:
        set sample, file(bam), file(bai) from ch_mappedBam2
    output:
        set sample, file("${sample}.intersectbed.bam") into ch_intersectBam
    
    script:
    """
    module load bedtools/2.27.1-gcc5
    intersectBed -abam ${bam} -b ${params.restrictedBed} > ${sample}.intersectbed.bam
    """
}

process CoverageBed {

    label 'small_1'

    input:
        set sample, file(bam), file(bai) from ch_mappedBam3
    output:
        set sample, file("${sample}.bedtools_hist_all.txt") into ch_bedtools
    
    script:
    """
    module load bedtools/2.27.1-gcc5
    coverageBed -b ${bam} -a ${params.restrictedBed} \
        -sorted -hist -g ${genome_file} | \
        grep all > "${sample}.bedtools_hist_all.txt"
    """
}

process ReadsMapped {

    label 'small_1'

    input:
        set sample, file(bam), file(bai) from ch_mappedBam4
    output:
        set sample, file("${sample}.mapped_to_genome.txt") into ch_onGenome

    module      'samtools/1.9'
    
    script:
    """
    samtools view -c -F4 ${bam} > "${sample}.mapped_to_genome.txt"
    """
}

process ReadsTotal {

    label 'small_1'

    input:
        set sample, file(bam), file(bai) from ch_mappedBam5
    output:
        set sample, file("${sample}.total_raw_reads.txt") into ch_onTotal

    module      'samtools/1.9'

    script:
    """
    samtools view -c ${bam} > "${sample}.total_raw_reads.txt"
    """
}
    
process TargetMapped {

    label 'small_1'

    input:
        set sample, file(bam) from ch_intersectBam
    output:
        set sample, file("${sample}.mapped_to_target.txt") into ch_onTarget

    module      'samtools/1.9'
   
    script:
    """
    samtools view -c -F4 ${bam} > ${sample}.mapped_to_target.txt
    """
}

ch_final = ch_bedtools.join(ch_onGenome)
ch_final2 = ch_final.join(ch_onTarget)
ch_final3 = ch_final2.join(ch_onTotal)

process collateData {

    label 'small_1'

    input:
        set sample, file(bedtools), file(onGenome), file(onTarget), file(onTotal) from ch_final3
    output:
        set sample, file("${sample}_summary_coverage.txt") into ch_out

    script:
    """
    module purge
    module load R/3.5.1
    Rscript --vanilla /projects/vh83/pipelines/code/modified_summary_stat.R \
            ${bedtools} \
            ${onGenome} \
            ${onTarget} \
            ${onTotal} \
            ${sample} \
            "${sample}_summary_coverage.txt"
    """
}

ch_out.map{a,b -> b}.collect().set{ch_out2}

process catStats {

    label 'small_1'

    input:
        file(stats) from ch_out2
    output:
        file("project_summary.txt") into ch_out3
    
    publishDir path: './metrics/', mode: 'copy'

    script:
    """
    cat ${rheader} ${stats} > "project_summary.txt"
    """

}


