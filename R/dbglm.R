dbsample<-function(con,...)  {UseMethod("dbsample")}
  
dbsample.tbl_monetdb <-function(tbl, n, N, variables, ... ){
  dbGetQuery(tbl$src$con, dbplyr::build_sql(con = tbl$src$con, "select ",dbplyr::ident(variables)," from (",dbplyr::sql(dbplyr::sql_render(tbl)), ") as foo sample ", as.integer(n)))
}

dbsample.tbl_sql <-function(tbl, n, N, variables, ... ){
  if (!is(tbl$src$con, 'SQLiteConnection')) stop("only implemented for RSQLite so far")
  dbGetQuery(tbl$src$con, dbplyr::build_sql(con = tbl$src$con, "select ",dbplyr::ident(variables)," from (", dbplyr::sql(dbplyr::sql_render(tbl)),  ") where abs(CAST(random() AS REAL))/9223372036854775808 <", as.double(n/N)))
  
} 
 
dbsample.tbl_df <-function(tbl, n, N, variables, ... ){
	tbl[sample(N,n),]	
}

dbsample.data.frame <-function(tbl, n, N, variables, ... ){
  tbl[sample(N,n),]	
}
 
dbsample.tbl_duckdb_connection<- function(tbl, n, N, variables, ... ){
  dbGetQuery(tbl$src$con, build_sql(con = tbl$src$con, dbnplyr::sql_render(tbl), build_sql(con = tbl$src$con, " ORDER BY RANDOM() LIMIT ", as.integer(n))))
}
dbsample.tbl_BigQueryConnection<- function(tbl, n, N, variables, ... ){
  dbGetQuery(tbl$src$con, build_sql(con = tbl$src$con, dbplyr::sql_render(tbl), build_sql(con = tbl$src$con, " ORDER BY rand() LIMIT ", as.integer(n))))
}

   
dbglm<-function(formula, family = binomial(), tbl, sd=FALSE,weights=.NotYetImplemented(), subset=.NotYetImplemented(), ...){   
	
 
  variables<-all.vars(formula)
  if (!(all(variables %in% colnames(tbl)))) stop("variables must be in data tbl")
  tbl2<-select(tbl,!!!syms(all.vars(formula)))
  if(class(tbl2)[1] == "tbl_BigQueryConnection"){
    n_ob<- tbl %>% summarise(n = n())
    N<- as.numeric(as.data.frame(n_ob)[1,])
    n<- round(N^(5/9))
    sdf<-dbsample(tbl2, n, N,  variables,...)
    isBQ<- T
  }else{
    N<- pull(summarise(tbl2, n()))
    n<-round(N^(5/9))
    sdf<-dbsample(tbl2, n, N,  variables,...)
    isBQ<- F
  }

  model0 <- glm(formula=formula,family=family, data=sdf, ...)
  if(sd){
  	  rval <- t(as.matrix(tbl2 %>% score_meansd(model0)))
  	  U <-rval[,1]*N
  	  beta0<-coef(model0)
  	  V0<- vcov(model0)
  	  inf<-solve(summary(model0)$cov.unscaled)
  	  seratio<- sqrt(diag(inf))/(rval[,2]*sqrt(n))
  	  V1<-V0*n/N
  	  V2<- outer(seratio,seratio)*V1
  	  beta1<-beta0+V1%*%U
  	  beta2<-beta0+V2%*%U

  	  list(beta0,beta1,beta2,V1,V2)

  } else {
  		U <- t(as.matrix(tbl2 %>% score_mean(model0, pass = isBQ)))*N
  		beta0<-coef(model0)
  		V0<- vcov(model0)
  		V1<-vcov(model0)*(n/N)
  		beta1<-beta0+V1%*%U
  		list(tildebeta=beta0,hatbeta=beta1,tildeV=V0,hatV=V1)

  }
}
strip_factor<-function(x) gsub("factor\\((.+)\\)","\\1",x)

parse_model_old <- function(model) {
  acceptable_formula(model)
  
  var_labels <- names(attr(model$terms, "dataClasses"))
  if (attr(model$terms, "response") == 1) var_labels <- var_labels[2:length(var_labels)]
  
  vars <- tibble(var = var_labels)
  
  xl <- model$xlevels
  if (length(xl) > 0) {
    xl_df <- seq_along(xl) %>%
      map_df(~tibble(
        var = names(xl[.x]),
        vals = xl[[.x]]
      ))
    vars <- vars %>%
      left_join(xl_df, by = "var") %>%
      mutate(fullname = paste0(.data$var, ifelse(is.na(.data$vals), "", .data$vals)))
  } else {
    vars <- vars %>%
      mutate(fullname = .data$var)
  }
  
  co <- model$coefficients
  
  est <- names(co) %>%
    map(~strsplit(.x, ":"))
  
  est_df <- seq_along(est) %>%
    map_df(~tibble(
      coefno = .x,
      fullname = est[[.x]][[1]]
    ))
  
  all_vals <- est_df %>%
    left_join(vars, by = "fullname") %>%
    mutate(vals = ifelse(.data$fullname == .data$var, "{{:}}", .data$vals)) %>%
    filter(!is.na(.data$var)) %>%
    filter(!is.na(.data$vals)) %>%
    select(-.data$fullname) %>%
    group_by(.data$coefno) %>%
    spread(.data$var, .data$vals)
  
  new_vals <- as_list(colnames(all_vals))
  names(new_vals) <- colnames(all_vals)
  
  all_vals <- as_tibble(new_vals) %>%
    mutate(coefno = 0L) %>%
    bind_rows(all_vals)
  
  colnames(all_vals) <- c("coefno", paste0("field_", (2:length(all_vals)) - 1))
  
  tidy <- as_tibble(model$coefficients) %>%
    rownames_to_column("labels") %>%
    rowid_to_column("coefno") %>%
    rename(estimate = .data$value) %>%
    mutate(type = "term") %>%
    bind_rows(tibble(
      coefno = 0,
      labels = "labels",
      estimate = 0,
      type = "variable"
    )) %>%
    left_join(all_vals, by = "coefno")
  
  qr <- qr.solve(qr.R(model$qr)) %>%
    as.data.frame() %>%
    rownames_to_column()
  
  colnames(qr) <- c("coef_labels", paste0("qr_", seq_len(nrow(qr))))
  
  cf <- as_list(c("labels", rep(NA, length(qr) - 1)))
  names(cf) <- names(qr)
  cf <- as_tibble(cf)
  cf <- cf %>% mutate_at(2:dim(cf)[2], as.double)
  
  qr <- qr %>%
    bind_rows(cf)
  
  # Leave as is for now.  Eventually need to change.
  tidy$labels <- qr$coef_labels
  
  tidy <- tidy %>%
    bind_cols(qr) %>%
    mutate(label_match = .data$coef_labels != .data$labels)
  
  if (!any(tidy$label_match)) {
    tidy <- tidy %>%
      select(
        -.data$coefno,
        -.data$coef_labels,
        -.data$label_match
      )
  } else {
    stop("There was a parsing error")
  }
  
  # TODO: figure out change add_variable
  tidy <- add_column(tidy,vals=NA)
  tidy <- add_row(tidy, labels = "model", vals = class(model)[[1]])
  tidy <- add_row(tidy, labels = "version", vals = "1.0")
  tidy <- add_row(tidy, labels = "residual", vals = as.character(model$df.residual))
  
  if (length(summary(model)$sigma^2) > 0) {
    tidy <- add_row(tidy, labels = "sigma2", vals = as.character(summary(model)$sigma^2))
  }
  
  if (!is.null(model$family$family)) {
    tidy <- add_row(tidy, labels = "family", vals = as.character(model$family$family))
  }
  
  if (!is.null(model$family$link)) {
    tidy <- add_row(tidy, labels = "link", vals = as.character(model$family$link))
  }
  
  offset <- model$call$offset
  if (!is.null(offset)) {
    tidy <- tidy %>%
      bind_rows(tibble(
        labels = "offset",
        vals = as.character(offset),
        type = "variable"
      ))
  }
  
  tidy
}


score_mean<- function(df, model,fitname="_fit_",residname="_resid_", pass) {
  df <- df %>% tidypredict_to_column(model, vars=c(fitname,"",""))
  
  parsedmodel<- parse_model_old(model)
  labels <- parsedmodel %>%
    filter(labels == "labels") %>%
    as.character()
  
  labels <- labels[4:length(labels)]
  labels <- c("estimate", labels)
  all_terms <- parsedmodel %>%
    filter(.data$type == "term") %>%
    select(- .data$type, -.data$labels)
  
  selection <- which(labels != "NA")
  all_terms <- all_terms[, which(labels != "NA")]
  colnames(all_terms) <- labels[which(labels != "NA")]
  
  response<-attr(terms(model),"variables")[[2]]
  fit<-sym(fitname)
  
  f <- seq_len(nrow(all_terms)) %>%
    map(~{
      vars <- strip_factor(colnames(all_terms))
      vals <- as.character(all_terms[.x, ])
      
      resid <- expr((!!!response)-(!!!fit))
      
      reg <- vars[vals == "{{:}}" & !is.na(vals) & vars != "estimate"]
      reg <- expr(!! syms(reg))
      
      field <- vars[vals != "{{:}}" & !is.na(vals) & vars != "estimate"]
      val <-  vals[vals != "{{:}}" & !is.na(vals) & vars != "estimate"]
      ie <- map2(syms(field), val, function(x, y) expr((!!x) == (!!y)))
      ie <- map(ie, function(x) expr(ifelse(!!x, 1.0, 0.0)))
      set <- c(reg, ie, resid)
      reduce(set, function(l, r) expr((!!! l) * (!!! r)))
    } )
  
  offset <- filter(parsedmodel, labels == "offset")
  if (nrow(offset) > 0) {
    f <- c(f, sym(offset$vals))
  }
  
  names(f)<-paste0("_u",seq_along(coef(model)))
  
  if(pass == T){
    df<- df %>% mutate(!!!f)
    df<- as.data.frame(df)
    out<- numeric(0)
    indi<- seq((length(coef(model))+2), ncol(df))
    for(i in indi){
      va<- mean(as.numeric(df[,i]))
      out<- c(out, va)
    }
    
    as.data.frame(t(as.data.frame(out)))
    
  }else{
    
    df %>% 
      mutate(!!!f) %>%
      summarise(!!!map(paste0("_u",seq_along(coef(model))), function(x) expr(mean(!!sym(x))))) %>%
      collect()
    
  }
}

score_meansd<- function(df, model,fitname="_fit_",residname="_resid_") {
	df <- df %>% tidypredict_to_column(model, vars=c(fitname,"",""))
	
  parsedmodel<- parse_model(model)
  labels <- parsedmodel %>%
    filter(labels == "labels") %>%
    as.character()
  
  labels <- labels[4:length(labels)]
  labels <- c("estimate", labels)
  all_terms <- parsedmodel %>%
    filter(.data$type == "term") %>%
    select(- .data$type, -.data$labels)
  
  selection <- which(labels != "NA")
  all_terms <- all_terms[, which(labels != "NA")]
  colnames(all_terms) <- labels[which(labels != "NA")]

  response<-attr(terms(model),"variables")[[2]]
  fit<-sym(fitname)
  
  f <- seq_len(nrow(all_terms)) %>%
    map(~{
      vars <- strip_factor(colnames(all_terms))
      vals <- as.character(all_terms[.x, ])
      
      resid <- expr((!!!response)-(!!!fit))
      
      reg <- vars[vals == "{{:}}" & !is.na(vals) & vars != "estimate"]
      reg <- expr(!! syms(reg))
      
      field <- vars[vals != "{{:}}" & !is.na(vals) & vars != "estimate"]
      val <-  vals[vals != "{{:}}" & !is.na(vals) & vars != "estimate"]
      ie <- map2(syms(field), val, function(x, y) expr((!!x) == (!!y)))
      ie <- map(ie, function(x) expr(ifelse(!!x, 1, 0)))
      set <- c(reg, ie, resid)
      reduce(set, function(l, r) expr((!!! l) * (!!! r)))
    } )
  
  offset <- filter(parsedmodel, labels == "offset")
  if (nrow(offset) > 0) {
    f <- c(f, sym(offset$vals))
  }
  
    names(f)<-paste0("_u",seq_along(coef(model)))

  
  rval <- df %>% mutate(!!!f) %>%
	summarise(!!!flatten(map(paste0("_u", seq_along(coef(model))), 
			function(x) c(expr(mean(!!sym(x))),expr(sd(!!sym(x))))))) %>% 
			collect()
  
  matrix(as.matrix(rval),nrow=2)
}
