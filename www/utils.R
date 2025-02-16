######## FOR NORMALIZATION ##################
############################################
RUVg.apply <- function(raw_counts, spikes) {
  # f = list of types

  set <- newSeqExpressionSet(as.matrix(raw_counts))
  # upper-quartile normalization by EDASeq
  set <- betweenLaneNormalization(set, which = "upper")
  if (!is.null(spikes)) {
    spikes <- intersect(spikes, rownames(raw_counts))
    set1 <- RUVg(set, spikes, k = 1) # spikes = negative control genes
    return(set1)
  } else {
    return(set)
  }
}

getEmpirical <- function(raw_counts, f) {
  # filter data by at least 1 value with >0 counts for each gene
  filter <- apply(raw_counts, 1, function(x) length(x[x > 0]) >= 2)
  filtered <- raw_counts[filter, ]
  set <- newSeqExpressionSet(as.matrix(filtered), phenoData = data.frame(f, row.names = colnames(raw_counts)))

  design <- model.matrix(~f, data = pData(set))
  y <- DGEList(counts = counts(set), group = f)
  y <- calcNormFactors(y, method = "upperquartile")
  y <- estimateGLMCommonDisp(y, design)
  y <- estimateGLMTagwiseDisp(y, design)
  fit <- glmFit(y, design)
  lrt <- glmLRT(fit, coef = 2)
  top <- topTags(lrt, n = nrow(set))$table
  n_row <- nrow(filtered)
  empirical <- rownames(set)[which(!(rownames(set) %in% rownames(top)[1:round(0.2 * n_row)]))]
  # set2 <- RUVg(set, empirical, k=1)
  return(empirical)
}

tpm <- function(counts, lengths) {
  rate <- counts / lengths
  tpm <- rate / sum(rate) * 1e6
  return(tpm)
}

fpkm <- function(counts, lengths) {
  rate <- counts / lengths
  fpkm <- rate / sum(counts) * 1e9
}
######### FOR DE ANALYSIS #######################3
################################################# 3

edgerApply <- function(DS, f, W_1 = NULL, f1, f2) {
  # W_1 calculated by RUVg with spikes (negative control genes)
  if (length(W_1) != length(f)) {
    W_1 <- NULL
  }
  y0 <- DGEList(counts = as.matrix(DS), group = f)
  # keep <- rowSums(cpm(y0)>2) >= 0.25*ncol(DS)
  # y0 <- y0[keep, , keep.lib.sizes=FALSE]

  if (!is.null(W_1)) {
    y <- calcNormFactors(y0, method = "upperquartile")
    ref <- data.frame("f" = f, "W_1" = W_1)
    rownames(ref) <- colnames(DS)
    design <- model.matrix(~ 0 + f + W_1, data = ref)
    colnames(design) <- c(levels(f), "W_1")
    y.disp <- estimateGLMCommonDisp(y, design)
    y.disp <- estimateGLMTagwiseDisp(y.disp, design)
    # fit <- glmQLFit(y.disp, design, robust=TRUE)   # glmQLFTest
    fit <- glmFit(y.disp, design)
  } else {
    y <- calcNormFactors(y0)
    design <- model.matrix(~ 0 + f)
    colnames(design) <- levels(f)
    y.disp <- estimateDisp(y, design, robust = TRUE)
    fit <- glmFit(y.disp, design)
  }
  crt <- makeContrasts(contrasts = paste(f2, f1, sep = "-"), levels = design)
  lrt <- glmLRT(fit, contrast = crt)
  res <- topTags(lrt, n = nrow(y0$counts)) # $table
  # print("res")
  # print(head(res$table))
  return(res)
}

edgerFilter <- function(res, FC = 2, p_val = 0.05) {
  # res = result object from edger
  res <- res$table
  colnames(res)[colnames(res) == "logFC"] <- "log2FC"
  res$log2FCabs <- abs(res$log2FC)
  # padj.na <- is.na(res$FDR);  res$FDR[padj.na] <- res$PValue[padj.na] # replace NA of padj by pval
  res <- res %>% rownames_to_column("Gene")
  res.cutoff <- filter(res, log2FCabs >= log2(FC), FDR <= p_val)
  return(res.cutoff)
}

deseqApply <- function(DS, f.df, W_1 = NULL, f1, f2) {
  # W_1 calculated by RUVg with spikes (negative control genes)
  if (length(W_1) != nrow(f.df)) {
    W_1 <- NULL
  }
  colnames(f.df) <- "f"
  f <- f.df[, 1]
  # aa <- ncol(DS);  keep <- apply(DS, 1, function(x) length(x[x>2])>=aa)  # filtering
  DS_filt <- DS # [keep,]
  if (!is.null(W_1)) {
    f.df$W_1 <- W_1
    dds <- DESeq2::DESeqDataSetFromMatrix(
      countData = as.matrix(DS_filt), # data frame or matrix
      colData = f.df,
      design = ~ W_1 + f
    )
  } else {
    dds <- DESeq2::DESeqDataSetFromMatrix(
      countData = as.matrix(DS_filt), # data frame or matrix
      colData = f.df,
      design = ~f
    )
  }
  ddsDE <- DESeq(dds)
  # print("from deseqApply");
  # print("W_1"); print(W_1)
  # print("dds.DE") ;print(head(ddsDE))
  res <- results(ddsDE, contrast = c("f", f2, f1))
  # print("from deseqApply");
  # print(res)
  return(res)
}

deseqFilter <- function(res, FC = 2, p_val = 0.05) {
  # res = result from deseqApply
  res <- as.data.frame(res)
  res$log2FCabs <- abs(res$log2FoldChange)
  # padj.na <- is.na(res$padj);  res$padj[padj.na] <- res$pvalue[padj.na] # replace NA of padj by pval
  res <- res %>% rownames_to_column("Gene")
  res.cutoff <- filter(res, log2FCabs >= log2(FC), padj <= p_val)
  colnames(res.cutoff)[colnames(res.cutoff) %in% c("log2FoldChange", "pvalue", "padj")] <- c("log2FC", "PValue", "FDR")
  # res.cutoff2 <- res.cutoff[,c("log2FoldChange","pvalue","padj","log2FCabs")]
  # colnames(res.cutoff2) <- c("log2FC","PValue","FDR","log2FCabs")
  return(res.cutoff)
}

noiseqbioApply <- function(DS, f.df, f1, f2) {
  # DS MUST be normalized before hand
  # DS <- df_raw_shiny
  # DS <- df_shiny
  # make sure rownames(f) = colnames(DS)
  colnames(f.df) <- "f"
  mydata <- NOISeq::readData(data = DS, factors = f.df)

  # noiseqbio or noiseq. if noiseq, q value cut off should be 0.8
  mynoiseqbio <- noiseqbio(mydata,
    conditions = c(f1, f2), k = 0.5, norm = "n", factor = "f", lc = 1, r = 20,
    adj = 1.5, plot = FALSE, a0per = 0.9, random.seed = 12345, filter = 1
  )
  # q = 1- pvalue
  mynoiseqbio.deg <- degenes(mynoiseqbio, q = 0.95, M = NULL) # data frame format; log2FC; volvano plot
  return(mynoiseqbio)
}

noiseqbioFilter <- function(mynoiseqbio, FC = 2, p_val = 0.05) {
  mynoiseqbio.deg <- degenes(mynoiseqbio, q = 0, M = NULL) # q = 1-p_val
  mynoiseqbio.deg$log2FCabs <- abs(mynoiseqbio.deg$log2FC)
  mynoiseqbio.deg <- mynoiseqbio.deg %>% rownames_to_column("Gene")
  # mynoiseqbio.deg <- filter(mynoiseqbio.deg, log2FCabs >= log2(FC))
  mynoiseqbio.deg$FDR <- 1 - mynoiseqbio.deg$prob
  return(mynoiseqbio.deg)
}

noiseqsimApply <- function(DS, f.df, f1, f2) {
  # DS MUST be normalized before hand
  # DS <- df_raw_shiny
  # DS <- df_shiny
  # make sure rownames(f) = colnames(DS)
  colnames(f.df) <- "f"
  mydata <- NOISeq::readData(data = DS, factors = f.df)

  mynoiseq <- noiseq(mydata,
    conditions = c(f1, f2), factor = "f", k = 0.5, norm = "n", pnr = 0.2,
    nss = 5, v = 0.02, lc = 1, replicates = "no"
  )
  # mynoiseq.deg = degenes(mynoiseq, q = 0.9, M = NULL)  # data frame format; M; no vocalno
  return(mynoiseq)
}

noiseqsimFilter <- function(mynoiseq, FC = 2) {
  mynoiseq.deg <- NOISeq::degenes(mynoiseq, q = 0, M = NULL) # q=0.8
  mynoiseq.deg$log2FCabs <- abs(mynoiseq.deg$M)
  mynoiseq.deg <- mynoiseq.deg %>% rownames_to_column("Gene")
  # mynoiseq.deg <- filter(mynoiseq.deg, log2FCabs >= log2(FC))
  mynoiseq.deg$FDR <- 1 - mynoiseq.deg$prob
  return(mynoiseq.deg)
}

# fold change between any 2 columns, no statistics involved
deWithoutStats <- function(DS, FC = 2, n_col = 1) {
  if (n_col < 2) n_col <- 2
  if (n_col > ncol(DS)) n_col <- ncol(DS) - 1
  keep <- apply(DS, 1, function(row) all(row > 0)) # all values must be > 0
  DS <- DS[keep, ]
  fcmatrix <- DS
  fcmatrix[, ] <- 0 # rownames(fcmatrix) <- rownames(DS)
  for (i in 1:ncol(DS)) {
    col_i_matrix <- matrix(rep(DS[, i], ncol(DS)), byrow = F)
    temp <- DS / col_i_matrix
    fcmatrix <- fcmatrix + (temp >= FC)
  }
  genes <- rownames(fcmatrix[rowSums(fcmatrix) >= n_col, ])
  return(DS[genes, ])
}

edgerDisp <- function(DS, f, ...) {
  y0 <- DGEList(counts = as.matrix(DS), group = f)
  keep <- rowSums(cpm(y0) > 2) >= 0.25 * ncol(DS)
  y0 <- y0[keep, , keep.lib.sizes = FALSE]
  y <- calcNormFactors(y0)

  design <- model.matrix(~f)
  y.disp <- estimateDisp(y, design, robust = TRUE)
  # plotBCV(y.disp)
  fit <- glmQLFit(y.disp, design, robust = TRUE)
  plotQLDisp(fit, ...)
  # return(fit)
}

deseqDisp <- function(DS, f.df, ...) {
  colnames(f.df) <- "f"
  f <- f.df[, 1]
  aa <- ncol(DS)
  keep <- apply(DS, 1, function(x) length(x[x > 2]) >= aa)
  DS_filt <- DS[keep, ]
  dds <- DESeq2::DESeqDataSetFromMatrix(
    countData = as.matrix(DS_filt), # data frame or matrix
    colData = f.df,
    design = ~f
  )
  # plotDispEsts(dds)
  # dds_disp <- DESeq(dds, test="LRT", reduced=~1)
  dds_disp <- DESeq(dds)
  plotDispEsts(dds_disp, ...)
}



########## heatmap #############




havingIP <- function() {
  if (.Platform$OS.type == "windows") {
    ipmessage <- system("ipconfig", intern = TRUE)
  } else {
    ipmessage <- system("ifconfig", intern = TRUE)
  }
  validIP <- "((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)[.]){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)"
  any(grep(validIP, ipmessage))
}

############ LOAD PACKAGES #################
############################################

loadPkg <- function() {
  if (length(find.package(package = "shinythemes", quiet = T)) > 0) {
    library(shinythemes)
  } else {
    print("Package shinythemes not installed")
    install.packages("shinythemes")
    print("Package shinythemes installed")
    library(shinythemes)
  }

  if (length(find.package(package = "corrplot", quiet = T)) > 0) {
    library(corrplot)
  } else {
    print("Package corrplot not installed")
    install.packages("corrplot")
    print("Package corrplot installed")
    library(corrplot)
  }

  if (length(find.package(package = "igraph", quiet = T)) > 0) {
    library(igraph)
  } else {
    print("Package igraph not installed")
    install.packages("igraph")
    print("Package igraph installed")
    library(igraph)
  }

  if (length(find.package(package = "ggraph", quiet = T)) > 0) {
    library(ggraph)
  } else {
    print("Package ggraph not installed")
    install.packages("ggraph")
    print("Package ggraph installed")
    library(ggraph)
  }

  if (length(find.package(package = "statmod", quiet = T)) > 0) {
    library(statmod)
  } else {
    print("Package statmod not installed")
    install.packages("statmod")
    print("Package statmod installed")
    library(statmod)
  }

  if (length(find.package(package = "ggplot2", quiet = T)) > 0) {
    library(ggplot2)
  } else {
    print("Package ggplot2 not installed")
    install.packages("ggplot2")
    print("Package ggplot2 installed")
    library(ggplot2)
  }

  if (length(find.package(package = "entropy", quiet = T)) > 0) {
    library(entropy)
  } else {
    print("Package entropy not installed")
    install.packages("entropy")
    print("Package entropy installed")
    library(entropy)
  }

  if (length(find.package(package = "moments", quiet = T)) > 0) {
    library(moments)
  } else {
    print("Package moments not installed")
    install.packages("moments")
    print("Package moments installed")
    library(moments)
  }

  if (length(find.package(package = "RUVSeq", quiet = T)) == 0) {
    BiocManager::install("RUVSeq", update = FALSE)
  }
  library(RUVSeq)

  if (length(find.package(package = "edgeR", quiet = T)) > 0) {
    library(edgeR)
  } else {
    print("Package edgeR not installed")
    BiocManager::install("edgeR", update = FALSE)
    print("Package edgeR installed")
    library(edgeR)
  }

  if (length(find.package(package = "DESeq2", quiet = T)) == 0) {
    BiocManager::install("DESeq2", update = FALSE)
  }
  library(DESeq2)

  if (length(find.package(package = "NOISeq", quiet = T)) == 0) {
    BiocManager::install("NOISeq", update = FALSE)
  }
  library(NOISeq)

  if (length(find.package(package = "NBPSeq", quiet = T)) == 0) {
    BiocManager::install("NBPSeq", update = FALSE)
  }
  library(NBPSeq)

  if (length(find.package(package = "AnnotationForge", quiet = T)) == 0) {
    BiocManager::install("AnnotationForge", update = FALSE)
  }
  library(AnnotationForge)

  if (length(find.package(package = "GOstats", quiet = T)) == 0) {
    BiocManager::install("GOstats", update = FALSE)
  }
  library(GOstats)

  if (length(find.package(package = "tibble", quiet = T)) > 0) {
    library(tibble)
  } else {
    print("Package tibble not installed")
    install.packages("tibble")
    print("Package tibble installed")
    library(tibble)
  }

  if (length(find.package(package = "dplyr", quiet = T)) > 0) {
    library(dplyr)
  } else {
    print("Package dplyr not installed")
    install.packages("dplyr")
    print("Package dplyr installed")
    library(dplyr)
  }

  # if (length(find.package(package = "ComplexHeatmap", quiet = T)) > 0) {
  #   library(ComplexHeatmap)
  # } else {
  #   print("Package ComplexHeatmap not installed")
  #   BiocManager::install("ComplexHeatmap", update = FALSE)
  #   print("Package ComplexHeatmap installed")
  #   library(ComplexHeatmap)
  # }

  if (length(find.package(package = "circlize", quiet = T)) > 0) {
    library(circlize)
  } else {
    print("Package circlize not installed")
    install.packages("circlize")
    print("Package circlize installed")
    library(circlize)
  }

  if (length(find.package(package = "actuar", quiet = T)) > 0) {
    library(actuar)
  } else {
    print("Package actuar not installed")
    install.packages("actuar")
    print("Package actuar installed")
    library(actuar)
  }

  if (length(find.package(package = "fitdistrplus", quiet = T)) > 0) {
    library(fitdistrplus)
  } else {
    print("Package fitdistrplus not installed")
    install.packages("fitdistrplus")
    print("Package fitdistrplus installed")
    library(fitdistrplus)
  }

  if (length(find.package(package = "Biobase", quiet = T)) > 0) {
    library("Biobase")
  } else {
    print("Package Biobase not installed")
    BiocManager::install("Biobase", update = FALSE)
    print("Package Biobase installed")
    library(org.Hs.eg.db)
  }

  if (length(find.package(package = "clusterProfiler", quiet = T)) > 0) {
    library(clusterProfiler)
  } else {
    print("Package clusterProfiler not installed")
    BiocManager::install("clusterProfiler", update = FALSE)
    print("Package clusterProfiler installed")
    library(clusterProfiler)
  }

  if (length(find.package(package = "DOSE", quiet = T)) > 0) {
    library(DOSE)
  } else {
    print("Package DOSE not installed")
    BiocManager::install("DOSE", update = FALSE)
    print("Package DOSE installed")
    library(DOSE)
  }

  if (length(find.package(package = "AnnotationDbi", quiet = T)) > 0) {
    library(AnnotationDbi)
  } else {
    print("Package AnnotationDbi not installed")
    BiocManager::install("AnnotationDbi", update = FALSE)
    print("Package clusterProfiler installed")
    library(AnnotationDbi)
  }

  if (length(find.package(package = "LSD", quiet = T)) > 0) {
    library(LSD)
  } else {
    print("Package LSD not installed")
    install.packages("LSD")
    print("Package LSD installed")
    library(LSD)
  }

  if (length(find.package(package = "DT", quiet = T)) > 0) {
    library(DT)
  } else {
    print("Package DT not installed")
    install.packages("DT")
    print("Package DT installed")
    library(DT)
  }

  if (length(find.package(package = "enrichR", quiet = T)) > 0) {
    library(enrichR)
  } else {
    print("Package enrichR not installed")
    install.packages("enrichR")
    print("Package enrichR installed")
    library(enrichR)
  }

  if (length(find.package(package = "plotly", quiet = T)) > 0) {
    library(plotly)
  } else {
    print("Package plotly not installed")
    install.packages("plotly")
    print("Package plotly installed")
    library(plotly)
  }

  if (length(find.package(package = "matrixStats", quiet = T)) > 0) {
    library(matrixStats)
  } else {
    print("Package matrixStats not installed")
    install.packages("matrixStats")
    print("Package matrixStats installed")
    library(matrixStats)
  }
}

#################### INSTALLATION SCRIPTS ###############
# sudo su - -c "R -e \"BiocManager::install("c('RUVSeq','edgeR','DESeq2','NOISeq','NBPSeq','AnnotationForge','GOstats','ComplexHeatmap','Biobase','clusterProfiler','DOSE','AnnotationDbi'), update = FALSE)\""