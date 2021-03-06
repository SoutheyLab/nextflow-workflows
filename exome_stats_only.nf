#!/usr/bin/env nextflow

// Required Inputs
refFolder      = file("/projects/vh83/reference/genomes/b37/bwa_0.7.12_index/")
inputDirectory = file('./fastqs')
panel_int      = file('/projects/vh83/reference/IDT_exome_panel/AML_AMLv3_Targets_Standard.b37.interval_list')
padded_int     = file('/projects/vh83/reference/IDT_exome_panel/AML_AMLv3_Targets_Standard.b37.interval_list')
panel_bed      = file('/projects/vh83/reference/IDT_exome_panel/AML_AMLv3_Targets_Standard.b37.bed')
padded_bed     = file('/projects/vh83/reference/IDT_exome_panel/AML_AMLv3_Targets_Standard.b37.bed')
tmp_dir        = file('/scratch/vh83/tmp/')


// Getting Reference Files
refBase          = "$refFolder/human_g1k_v37_decoy"
ref              = file("${refBase}.fasta")
refDict          = file("${refBase}.dict")
refFai           = file("${refBase}.fasta.fai")
millsIndels      = file("/projects/vh83/reference/genomes/b37/accessory_files/Mills_and_1000G_gold_standard.indels.b37.vcf")
knownIndels      = file("/projects/vh83/reference/genomes/b37/accessory_files/1000G_phase1.indels.b37.vcf")
dbSNP            = file("/projects/vh83/reference/genomes/b37/accessory_files/dbsnp_138.b37.vcf")

/*

mills_grch37: reference/Mills_and_1000G_gold_standard.indels.b37.vcf
one_k_g_grch37_indels: reference/1000G_phase1.indels.b37.vcf
one_k_g_snps: reference/1000G_omni2.5.b37.vcf
one_k_g_highconf_snps: reference/1000G_phase1.snps.high_confidence.b37.vcf
one_k_g_indels: reference/1000G_phase1.indels.b37.vcf
hapmap: reference/hapmap_3.3.b37.vcf
interval_grch37: reference/Broad.human.exome.b37.interval_list
dbsnp_grch37: reference/dbsnp_138.b37.vcf
CEU_mergeGvcf: reference/CEU_mergeGvcf.vcf
FIN_mergeGvcf: reference/FIN_mergeGvcf.vcf
GBR_mergeGvcf: reference/GBR_mergeGvcf.vcf
*/

// Tools
picardJar          = '~/picard.jar'
gatkJar            = '/usr/local/gatk/3.7/bin/GenomeAnalysisTK.jar'
bwaModule          = 'bwa/0.7.17-gcc5'
samtoolsModule     = 'samtools/1.9'
gatkModule         = 'gatk/3.7'
rModule            = 'R/3.5.1'          
fgbioJar           = '/usr/local/fgbio/0.9.0/target/fgbio-0.9.0-17cb5fb-SNAPSHOT.jar'

// Global Resource Configuration Options
globalExecutor    = 'slurm'
globalStageInMode = 'symlink'
globalCores       = 1
bwaCores	      = 12
vardictCores      = 4
globalMemoryS     = '6 GB'
globalMemoryM     = '32 GB'
globalMemoryL     = '64 GB'
globalTimeS       = '8m'
globalTimeM       = '1h'
globalTimeL       = '24h'
globalQueueS      = 'short'
globalQueueL      = 'comp'

// Creating channel from input directory
//create channel flat because we want to join it later, and the tuple makes that more annoying than I want it to be
ch_inputFiles = Channel.fromFilePairs("$inputDirectory/*R{1,2}.fastq.gz", flat: true)


process createUnmappedBam {
    
    publishDir path: './output/intermediate', mode: 'copy'
    
    input:
        set baseName, file(R1), file(R2) from ch_inputFiles
    output:
        set baseName, file("${baseName}.unmapped.bam") into ch_unmappedBams

    publishDir path: './output/intermediate', mode: 'copy'
    
    cache       'lenient'
    executor    globalExecutor
    stageInMode globalStageInMode
    cpus        1
    module      'fgbio'
    module      'java'
    memory      globalMemoryM
    time        '3h'
    queue       globalQueueL

    script:
    """
    java -Xmx30g -Djava.io.tmpdir=$tmp_dir -XX:+AggressiveOpts -XX:+AggressiveHeap \
        -jar $fgbioJar FastqToBam --input $R1 $R2 --output "${baseName}.unmapped.bam" --read-structures +T +T \
        --sample "${baseName}" --read-group-id "${baseName}" --library A --platform illumina --sort true
    """
}

process markAdaptors {

    publishDir path: './output/intermediate', mode: 'copy'

    input:
        set baseName, file(bam) from ch_unmappedBams
    output:
        set baseName, file("${baseName}.unmapped.marked.bam"),
                      file("${baseName}.unmapped.marked_metrics.tsv") into ch_markedBams

    cache       'lenient'
    executor    globalExecutor
    stageInMode globalStageInMode
    cpus        1
    module      'java'
    memory      globalMemoryM
    time        '3h'
    queue       globalQueueL

    script:
    """
    java -Dpicard.useLegacyParser=false -Xmx30g -jar $picardJar MarkIlluminaAdapters \
        -INPUT $bam \
        -OUTPUT "${baseName}.unmapped.marked.bam" \
        -METRICS "${baseName}.unmapped.marked_metrics.tsv"
    """
}


process alignBwa {
    input:
        set baseName, file(bam), file(metrics) from ch_markedBams
    output:
        set baseName, file("${baseName}.mapped.bam") into ch_mappedBams

    publishDir path: './output/intermediate', mode: 'copy'

    cache       'lenient'
    executor    globalExecutor
    stageInMode globalStageInMode
    module      bwaModule
    module	    'samtools'
    module      'picard'
    cpus        bwaCores
    memory      globalMemoryM
    time        globalTimeL
    queue       globalQueueL

    script:
    """
    set -o pipefail
    java -Dpicard.useLegacyParser=false -Xmx6G -jar $picardJar SamToFastq \
        -I "$bam" \
        -FASTQ '/dev/stdout' -CLIPPING_ATTRIBUTE XT -CLIPPING_ACTION 2 \
        -INTERLEAVE true -NON_PF true -TMP_DIR "$tmp_dir" | \
    bwa mem -M -t ${task.cpus} -p $ref /dev/stdin | \
    java -Dpicard.useLegacyParser=false -Xmx6G -jar $picardJar MergeBamAlignment \
        -ALIGNED_BAM '/dev/stdin' -UNMAPPED_BAM "$bam" \
        -OUTPUT "${baseName}.mapped.bam" -R "$ref" -ADD_MATE_CIGAR true \
        -CLIP_ADAPTERS false -MAX_INSERTIONS_OR_DELETIONS '-1' \
        -PRIMARY_ALIGNMENT_STRATEGY MostDistant -SO queryname -ATTRIBUTES_TO_RETAIN XS -TMP_DIR "$tmp_dir"
    """
}

process markDuplicatesPicard {
    input:
        set baseName, bam from ch_mappedBams 
    output:
        set baseName, file("${baseName}.mapped.marked.bam") into ch_markedBamFiles
        set baseName, file("${baseName}.markduplicates.metrics") into ch_metrics

    publishDir path: './output/metrics/markduplicates', mode: 'copy'

    cache       'lenient'
    executor    globalExecutor
    stageInMode globalStageInMode
    cpus        1
    memory      globalMemoryM
    time        globalTimeL
    queue       globalQueueL

    // TODO: CLEAR_DT=false option in GATK pipeline but not supported by 
    //       this version of picard.
    //       ADD_PG_TAG_TO_READS=false also not supported.
    """
    java -Dpicard.useLegacyParser=false -Xmx32G -jar $picardJar MarkDuplicates \
        -INPUT $bam \
        -OUTPUT ${baseName}.mapped.marked.bam \
        -METRICS_FILE ${baseName}.markduplicates.metrics \
        -VALIDATION_STRINGENCY SILENT \
        -OPTICAL_DUPLICATE_PIXEL_DISTANCE 2500 \
        -ASSUME_SORT_ORDER queryname
    """
}

process sortBam {
    input:
        set baseName, file(markedBam) from ch_markedBamFiles
    output:
        set baseName, file("${baseName}.mapped.marked.sorted.bam") into ch_sortedBamFiles

    cache       'lenient'
    executor    globalExecutor
    stageInMode globalStageInMode
    cpus        1
    memory      globalMemoryS
    time        globalTimeL
    queue       globalQueueL

    """
    java -Djava.io.tmpdir=$tmp_dir -Dpicard.useLegacyParser=false -Xmx4g -jar $picardJar SortSam \
        -INPUT $markedBam \
        -OUTPUT ${baseName}.mapped.marked.sorted.bam \
        -SORT_ORDER coordinate \
        -CREATE_INDEX false \
        -CREATE_MD5_FILE false \
        -MAX_RECORDS_IN_RAM 300000
    """
}

process indexBam {
    input:
        set baseName, file(bam) from ch_sortedBamFiles
    output:
        set baseName, file(bam), file("${baseName}.mapped.marked.sorted.bam.bai") into ch_forHSMetrics
    publishDir path: './output/intermediate', mode: 'copy'

    cache       'lenient'
    executor    globalExecutor
    stageInMode globalStageInMode
    module      'samtools'
    cpus        globalCores
    memory      globalMemoryM
    time        globalTimeL
    queue       globalQueueL

    script:
    """
    samtools index $bam ${baseName}.mapped.marked.sorted.bam.bai
    """
}

process collectHSMetrics {

    input:
        set sample, file(bam), file(bai) from ch_forHSMetrics
    output:
        set sample, file("*.HSmetrics.txt"), file("*.perbase.txt"), file("*.pertarget.txt") into ch_metrics_unused2
    
    publishDir path: './output/metrics/coverage', mode: 'copy'
    
    executor    globalExecutor
    stageInMode globalStageInMode
    cpus        1
    memory      globalMemoryM
    time        globalTimeL
    queue       globalQueueL

    script:

    """
    module purge
    module load R/3.5.1
    java -Dpicard.useLegacyParser=false -Xmx6G -jar ${picardJar} CollectHsMetrics \
        -I ${bam} \
        -O "${sample}.HSmetrics.txt" \
        -R ${ref} \
        -BI $panel_int \
        -TI $padded_int \
        --PER_BASE_COVERAGE "${sample}.perbase.txt" \
        --PER_TARGET_COVERAGE "${sample}.pertarget.txt"
    """
}
