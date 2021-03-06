#!/usr/bin/env nextflow

bazamJar = '/home/jste0021/scripts/bazam/build/libs/bazam.jar'

Channel.fromPath("./*.bam").map{file -> tuple(file.name.take(file.name.lastIndexOf('.')), file)}.set{ch_bams}

process runBazam {

  label 'medium_6h'

  publishDir path: './BAZAM', mode: 'copy'

  input:
    set sample, file(bam) from ch_bams
  output:
    set sample, file("${sample}_R1.fastq.gz"), file("${sample}_R2.fastq.gz")

  module 'samtools'
  
  script:
  """
  samtools index $bam
  java -Xmx${task.memory.toGiga() - 2}g -jar $bazamJar -n ${task.cpus} -bam ${bam} -r1 ${sample}_R1.fastq.gz -r2 ${sample}_R2.fastq.gz
  """
}




