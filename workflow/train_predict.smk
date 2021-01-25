# The data processing and analysis steps to train the PREPRINT classifier and
# to predict the genome-wide enhancers.

# First, define transcription start sites (TSS) of protein coding genes 
rule define_TSS:
	input:
		f'{gencode_dir}/gencode.v27lift37.annotation.gtf.gz',
		f'{code_dir}/define_TSS.R'
	output:
		f'{gencode_dir}/GENCODE.RData',
		f'{gencode_dir}/GR_Gencode_protein_coding_TSS.RDS',
		f'{gencode_dir}/GR_Gencode_protein_coding_TSS_positive.RDS',
		f'{gencode_dir}/GR_Gencode_TSS.RDS',
		f'{gencode_dir}/GR_Gencode_TSS_positive.RDS'
	shell:
		'Rscript {code_dir}/define_TSS.R --pathToDir={data_dir}'

# Rules for downloading various files
rule download_gencode:
	input:
	output: f'{gencode_dir}/gencode.v27lift37.annotation.gtf.gz'
	shell: 'wget ftp://ftp.ebi.ac.uk/pub/databases/gencode/Gencode_human/release_27/GRCh37_mapping/gencode.v27lift37.annotation.gtf.gz -O {output}'

rule download_blacklists:
	input:
	output: f'{blacklists_dir}/{{file}}'
	shell: 'wget http://hgdownload.cse.ucsc.edu/goldenpath/hg19/encodeDCC/wgEncodeMapability/{wildcards.file} -O {output}'

# Definition and extraction of the training and test data enhancers
# 
# The size of ChIP-seq coverage profile window centered at enhancers and
# resolution of the enhancer pattern can be defined. Also the number of enhancers
# can vary. Enhancers whose distance to promoters is less than 2000 are removed.
# This is time and memory consuming step, can be done in less than 4 hours using
# 17 cpus and 3G mem per cpu. Example whown for the K562 cell line data. The data
# is not normalized wrt. data from any other cell line ( normalizeBool=FALSE).
rule extract_enhancers:
	input:
		bam_files=expand(f'{bam_shifted_dir}/{{data_type}}.bam', data_type=all_data_types),
		p300=f'{raw_data_dir}/wgEncodeAwgTfbsSydhK562P300IggrabUniPk.narrowPeak.gz',
		DNase=f'{raw_data_dir}/wgEncodeOpenChromDnaseK562PkV2.narrowPeak.gz',
		blacklist_Dac=f'{blacklists_dir}/wgEncodeDacMapabilityConsensusExcludable.bed.gz',
		blacklist_Duke=f'{blacklists_dir}/wgEncodeDukeMapabilityRegionsExcludable.bed.gz',
		protein_coding_positive=f'{gencode_dir}/GR_Gencode_protein_coding_TSS_positive.RDS',
		code=f'{code_dir}/extract_enhancers.R',
	output:
		f'{data_r_dir}/{config["extract_enhancers"]["N"]}_enhancers_bin_{config["binSize"]}_window_{config["window"]}.RData'
	shell:
		r'''
		Rscript {code_dir}/extract_enhancers.R \
			--window={config[window]} \
			--binSize={config[binSize]} \
			--N={config[extract_enhancers][N]} \
			--distToPromoter={config[extract_enhancers][distToPromotor]} \
			--pathToDir={data_dir} \
			--cellLine={cell_line} \
			--p300File={input.p300} \
			--DNaseFile={input.DNase} \
			--normalize=FALSE \
			--NormCellLine=""
		'''

# Definition and extraction of training and test data promoters
rule extract_promoters:
	input:
		bam_files=expand(f'{bam_shifted_dir}/{{data_type}}.bam', data_type=all_data_types),
		DNase=f'{raw_data_dir}/wgEncodeOpenChromDnaseK562PkV2.narrowPeak.gz',
		blacklist_Dac=f'{blacklists_dir}/wgEncodeDacMapabilityConsensusExcludable.bed.gz',
		blacklist_Duke=f'{blacklists_dir}/wgEncodeDukeMapabilityRegionsExcludable.bed.gz',
		protein_coding=f'{gencode_dir}/GR_Gencode_protein_coding_TSS.RDS',
		protein_coding_positive=f'{gencode_dir}/GR_Gencode_protein_coding_TSS_positive.RDS',
		code=f'{code_dir}/extract_promoters.R',
	output:
		f'{data_r_dir}/{config["extract_promoters"]["N"]}_promoters_bin_{config["binSize"]}_window_{config["window"]}.RData',
	shell:
		r'''
		Rscript {code_dir}/extract_promoters.R \
			--window={config[window]} \
			--binSize={config[binSize]} \
			--N={config[extract_promoters][N]} \
			--tssdist={config[extract_promoters][between_TSS_distance]} \
			--pathToDir={data_dir} \
			--cellLine={cell_line} \
			--DNaseFile={input.DNase} \
			--normalize=FALSE \
			--NormCellLine=""
		'''

# Process whole-genome data
#
# Generate the data for the whole genome using bin size 100 (resolution). The
# files generated by this step are needed to generate the random genomic
# locations. Example for chromosome 1 and chromatin feature Ctcf
chroms=["chr1", "chr2", "chr3", "chr4", "chr5", "chr6", "chr7", "chr8", "chr9",
		"chr10", "chr11", "chr12", "chr13", "chr14", "chr15", "chr16", "chr17",
		"chr18", "chr19", "chr20", "chr21", "chr22", "chrX"]
rule create_intervals_whole_genome:
	input: f'{code_dir}/create_intervals_whole_genome.R'
	output: expand(f'{intervals_dir}/{{chrom}}.bed', chrom=chroms)
	shell: 'Rscript {code_dir}/create_intervals_whole_genome.R --binSize={config[binSize]} --output={intervals_dir}'


rule bedtools_multicov:
	input:
		bam_file=f'{bam_shifted_dir}/{{mod}}.bam',
		intervals=f'{intervals_dir}/{{chrom}}.bed',
	output:
		f'{intervals_dir}/{{mod}}/{{chrom}}.bed'
	shell:
		r'''
		bedtools multicov \
			-bams {input.bam_file} \
			-bed {input.intervals} \
		| sort -k 1,1 -k2,2 -n \
		| cut -f 1-3,7 \
		> {output}
		'''

# Combine all data for each chromosome, do this for all chromosomes
union_bedgraph_names = ' '.join(all_data_types)
rule union_bedgraph:
	input:
		bed_files=expand(f'{intervals_dir}/{{data_type}}/{{{{chrom}}}}.bed', data_type=all_data_types),
		code=f'{code_dir}/union_bedgraph.sh'
	output:
		f'{intervals_dir}/all_{{chrom}}.bedGraph'
	shell:
		'bedtools unionbedg -header -i {input.bed_files} -names {union_bedgraph_names} > {output}'

rule extract_nonzero_bins:
	input:
		f'{intervals_dir}/all_{{chrom}}.bedGraph'
	output:
		f'{intervals_dir}/nozero_regions_only_{{chrom}}.bed'
	shell:
		'bash {code_dir}/extract_nonzero_bins.sh {wildcards.chrom} {cell_line} {config[binSize]} {intervals_dir}'
