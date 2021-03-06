# export alignment to wig file
# - each read (pair) "lives" on a single base:
#     pairs on the middle of the fragment
#     singles on the 5'-end base shifted by "shift" towards their 3'-end
# - multiple samples can be automatically normalized to one another
# - multiple bam files with identical sample name can be combined into the same file (track)
# - wig files can be compressed
#
# proj        : qProject object
# file        : wig file name(s) (will be compressed if file QuasR:::compressedFileFormat(file) != "none"
# collapseBySample : create one track per unique sample name
# binsize     : stepInterval and windowSize for the fixedStep wig file
# shift       : only for single read projects; shift read
# strand      : only include alignments on '+', '-' or '*' (any) strand
# scaling     : scale multiple tracks to one another?
# tracknames  : names for display in track header
# log2p1      : transform alignment count by log2(x+1)
# colors      : colors for tracks
# mapqMin     : minimum mapping quality (MAPQ >= mapqMin)
# mapqMax     : maximum mapping quality (MAPQ <= mapqMax)
# absIsizeMin : minimum absolute insert size (TLEN >= absIsizeMin)
# absIsizeMax : maximum absolute insert size (TLEN <= absIsizeMax)
qExportWig <- function(proj,
                       file=NULL,
                       collapseBySample=TRUE,
                       binsize=100L,
                       shift=0L,
                       strand=c("*","+","-"),
                       scaling=TRUE,
                       tracknames=NULL,
                       log2p1=FALSE,
                       colors=c("#1B9E77", "#D95F02", "#7570B3", "#E7298A", "#66A61E", "#E6AB02", "#A6761D", "#666666"),
                       includeSecondary=TRUE,
                       mapqMin=0L,
                       mapqMax=255L,
                       absIsizeMin=NULL,
                       absIsizeMax=NULL,
                       createBigWig=FALSE)
{
    # validate parameters
    # ...proj
    if(!is(proj, "qProject"))
        stop("'proj' must be a 'qProject' object")

    if(collapseBySample) {
        bamfiles <- split(proj@alignments$FileName, as.factor(proj@alignments$SampleName))[unique(proj@alignments$SampleName)]
        samplenames <- names(bamfiles)
    } else {
        bamfiles <- as.list(proj@alignments$FileName)
        samplenames <- proj@alignments$SampleName
    }
    n <- length(bamfiles)
    paired <- proj@paired != "no"

    # ...strand
    strand <- match.arg(strand)
    if(length(strand) != 1)
        stop("'strand' has to be a single character value: '+', '-' or '*'")
    
    # ...tracknames
    if(is.null(tracknames)) {
        tracknames <- if(collapseBySample) samplenames else displayNames(proj)
        if(strand[1] != "*")
            tracknames <- sprintf("%s (%s)",tracknames,strand)
    }
    
    # ...file
    if(is.null(file)) {
        fileExt <- if(createBigWig) ".bw" else ".wig.gz"
        if(collapseBySample)
            file <- paste0(samplenames, fileExt)
        else
            file <- paste0(displayNames(proj), fileExt)
    } else if(length(file) != n) {
        stop(sprintf("the length of 'file' (%d) does not match the number of wig files to be generated (%d)",length(file),n))
    }
    if(createBigWig && any(!grepl(".bw$",file)))
        stop("file names have to end with '.bw' for createBigWig=TRUE")
    compressFormat <- compressedFileFormat(file)
    if(!all(compressFormat %in% c("none","gzip")))
        stop("only gzip compressed wig files (extension '.gz') are supported")
    compress <- compressFormat == "gzip"
    if(length(compress)==1)
        compress <- rep(compress,n)

    # ...binsize
    if(length(binsize)!=1)
        stop("'binsize' must be a single integer value")
    binsize <- as.integer(binsize)
    if(is.na(binsize) || binsize<1)
        stop("'binsize' must be a positive integer value")

    # ...shift
    shift <- as.integer(shift)
    if(any(is.na(shift)))
        stop("'shift' has to be a vector of integer values")
    if(length(shift)!=1 && length(shift)!=n)
        stop(sprintf("'shift' has to contain either a single value or one value per output wig file (%d)",n))
    if(paired && shift!=0L) {
        warning("ignoring 'shift' value for paired-end alignments (will calculate alignment-specific values)")
        shift <- 0L
    }
    if(length(shift)==1)
        shift <- rep(shift,n)

    # ...scaling
    fact <- rep(1,n)
    if(scaling) {
        message("collecting mapping statistics for scaling...", appendLF=FALSE)
        tmp <- alignmentStats(proj, collapseBySample=collapseBySample)
        N <- tmp[grepl(":genome$",rownames(tmp)),'mapped']
        names(N) <- sub(":genome$","",names(N))
        if(is.logical(scaling)) {
            #fact <- min(N) /N
            fact <- mean(N) /N
        } else if(is.numeric(scaling) && length(scaling)==1 && scaling>0) {
            fact <- scaling /N
        } else {
            stop("'scaling' must be either 'TRUE', 'FALSE' or a positive numerical value")
        }
        message("done")
    }

    # ...log2p1
    if(length(log2p1) != 1 || !is.logical(log2p1))
        stop("'log2p1' has to be either 'TRUE' or 'FALSE'")
    log2p1 <- rep(log2p1,n)
    
    # ...colors
    if(length(colors) < n)
        colors <- colorRampPalette(colors)(n)
    colors <- apply(col2rgb(colors),2,paste,collapse=",")

    # ...includeSecondary
    if(length(includeSecondary) != 1 || !is.logical(includeSecondary))
        stop("'includeSecondary' must be of type logical(1)")

    # ...mapping qualities
    if(length(mapqMin) != 1 || !is.integer(mapqMin) || any(is.na(mapqMin)) || min(mapqMin) < 0L || max(mapqMax) > 255L)
        stop("'mapqMin' must be of type integer(1) and have a values between 0 and 255")
    mapqMin <- rep(mapqMin,n)
    if(length(mapqMax) != 1 || !is.integer(mapqMax) || any(is.na(mapqMax)) || min(mapqMax) < 0L || max(mapqMax) > 255L)
        stop("'mapqMax' must be of type integer(1) and have a values between 0 and 255")
    mapqMax <- rep(mapqMax,n)

    # ...absolute insert size
    if((!is.null(absIsizeMin) || !is.null(absIsizeMax)) && proj@paired == "no")
        stop("'absIsizeMin' and 'absIsizeMax' can only be used for paired-end experiments")
    if(is.null(absIsizeMin)) # -1L -> do not apply TLEN filtering
        absIsizeMin <- -1L
    if(is.null(absIsizeMax))
        absIsizeMax <- -1L
    
    # generate the wig file(s)
    message("start creating ",if(createBigWig) "bigWig" else "wig"," file",if(n>1) "s" else "","...")
    tempwigfile <- if(createBigWig) sapply(1:n, function(i) tempfile(fileext=".wig")) else file
    if(createBigWig) {
        tmp <- Rsamtools::scanBamHeader(bamfiles[[1]][1])[[1]]$targets
        si <- GenomeInfoDb::Seqinfo(names(tmp), tmp)
    }
    lapply(1:n, function(i) {
        message("  ",file[i]," (",tracknames[i],")")
        .Call("bamfileToWig", as.character(bamfiles[[i]]), as.character(tempwigfile[i]), as.logical(paired[1]),
              as.integer(binsize[1]), as.integer(shift[i]), as.character(strand[1]), as.numeric(fact[i]),
              as.character(tracknames[i]), as.logical(log2p1[i]),
              as.character(colors[i]), as.logical(compress[i]), as.logical(includeSecondary[1]),
              mapqMin[i], mapqMax[i], as.integer(absIsizeMin), as.integer(absIsizeMax), PACKAGE="QuasR")
        if(createBigWig) {
            rtracklayer::wigToBigWig(tempwigfile[i], si, file[i])
            unlink(tempwigfile[i])
        }
    })
    message("done")
    
    return(invisible(file))
}
