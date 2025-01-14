aeddo <- function(
    data,
    formula,
    seasonality = FALSE,
    trend = FALSE,
    theta,
    lower = -Inf,
    upper = Inf,
    method = "BFGS",
    model = NA_character_,
    cpp.dir = NULL,
    cpp = NULL,
    k = 36,
    sig.level = 0.95,
    excludePastOutbreaks = TRUE,
    CI = FALSE,
    period = "month"
    ){
  
  if(is.null(cpp) & is.na(model)){
    stop("Incorrect specification. ",
         "Atleast one of the arguements 'model' ",
         "or 'cpp' must be parsed.")
  }
  
  if(!is.na(model)){
    if(model %in% c("PoissonNormal", "PoissonGamma")){
      TMB::compile(file = paste0(cpp.dir, model,".cpp"))
    }else{
      stop("Incorrect specification. ",
           "'model' can only take the arguements ",
           "'PoissonNormal' or 'PoissonGamma'.")
    }
  }else{
    if(is.character(cpp)){
      if(grepl(pattern = ".cpp", x = cpp, fixed = TRUE)){
        if(file.exists(paste0(cpp.dir,cpp))){
          # Compile the C++ file
          TMB::compile(file =  paste0(cpp.dir,cpp))
          # Extract the model name
          model <- gsub(pattern = ".cpp", replacement = "", x = cpp)
        }else{
          stop("Incorrect specification. ",
               "The parsed .cpp file does not exits ",
               "in this directory.")
        }
      }else{
        stop("Incorrect specification. ",
             "'cpp' must link to a valid .cpp ",
             "file.")
      }
    }else{
      stop("Incorrect specification. ",
           "'cpp' must be a character string ",
           "linking to a .cpp file.")
    } 
  }
  
  # Add dynlib extension
  dyn.load(TMB::dynlib(paste0(cpp.dir, model)))
  
  # Extract the months
  Dates <- dplyr::`%>%`(data, dplyr::reframe(Date = unique(Date)))$Date
  
  # Count the number of observations
  nObs <- length(Dates)
  
  
  # Add seasonality
  if(seasonality){
    if(period == "month"){
      data <- dplyr::`%>%`(
        data,
        dplyr::mutate(periodInYear = as.integer(format(Date, "%m")))
      )  
    }else if(period == "week"){
      data <- dplyr::`%>%`(
        data,
        dplyr::mutate(periodInYear = as.integer(format(Date, "%W")))
      )
    }
  }
  
  # Make a placeholder for the 'results' and 'pastOutbreaks'
  results <- dplyr::tibble()
  
  if(excludePastOutbreaks == TRUE){
    pastOutbreaks <- dplyr::tibble()
  }
  # for(i in 1:6){
  for(i in 1:(nObs-k)){
    
    # Compute the dates in window
    datesInWindow <- Dates[i:(i+k-1)]
    #... and the reference date
    refDate <- Dates[i+k]
    
    # Extract the observations in this window
    yWindow <- dplyr::`%>%`(
      data,
      dplyr::filter(Date %in% datesInWindow)
      )
    #... and the reference data
    refData <- dplyr::`%>%`(
      data,
      dplyr::filter(Date %in% refDate)
    )
    # Add trend
    if(trend){
      if(period == "month"){
        yWindow <- dplyr::`%>%`(
          yWindow,
          dplyr::mutate(t = lubridate::interval(
            Dates[i],
            Date) %/% months(1) - k + 1
          )
        )
        refData <- dplyr::`%>%`(
          refData,
          dplyr::mutate(t = lubridate::interval(
            Dates[i],
            Date) %/% months(1) - k + 1
          )
        )
      }else if(period == "week"){
        yWindow <- dplyr::`%>%`(
          yWindow,
          dplyr::mutate(t = 1:k-k)
        )
        refData <- dplyr::`%>%`(
          refData,
          dplyr::mutate(t = 0)
        )
      }
      
    }
    
    # Exclude past observations, if they were deemed an outbreak
    # Turned on by 'excludePastOutbreaks = TRUE'
    if(excludePastOutbreaks == TRUE){
      if(nrow(pastOutbreaks) > 0){
        yWindow <- dplyr::`%>%`(
          yWindow,
          dplyr::setdiff(pastOutbreaks)
        )
      }
    }
    
    # Construct the design matrix
    designMatrix <- model.matrix(object = formula, data = yWindow)
    
    if(model == "PoissonNormal"){
      
      # Make the function for the window
      PoisN <- TMB::MakeADFun(
        data = list(y = yWindow$y, n = yWindow$n, X = designMatrix),
        parameters = list(u = rep(1, length(yWindow$y)),
                          beta = theta[1:ncol(designMatrix)],
                          log_sigma_u = theta[-(1:ncol(designMatrix))]),
        hessian = TRUE,
        random = "u",
        method = method,
        DLL = model,
        silent = TRUE
      )
      
      if(method == "L-BFGS-B"){
        PoisN$lower <- lower
        PoisN$upper <- upper
      }
    
      # Optimize the function
      opt <- do.call(what = "optim", args = PoisN)
      
      ## Report on the random effects
      sdRep <- TMB::sdreport(PoisN)
      
      # Make a design matrix for the reference data
      refDesign <- model.matrix(object = formula, data = refData)
      
      # Make the function for the reference datad
      refPoisN <- TMB::MakeADFun(
        data = list(y = refData$y, n = refData$n, X = refDesign),
        parameters = list(u = rep(1, length(refData$y)),
                          beta = theta[1:ncol(refDesign)],
                          log_sigma_u = theta[-(1:ncol(refDesign))]),
        random = "u",
        DLL = model,
        silent = TRUE
      )
      
      # Calculate the random effects
      refRep <- TMB::sdreport(obj = refPoisN, par.fixed = opt$par, hessian.fixed = opt$hessian)
      
      # Calculate the random effects and related information
      ran.ef <- dplyr::tibble(
        ref.date = refDate,
        ageGroup = refData$ageGroup,
        n = refData$n,
        y = refData$y,
        log_sigma = opt$par[-(1:ncol(designMatrix))],
        lambda = c(exp(refDesign %*% opt$par[1:ncol(refDesign)] - log(n))),
        u = refRep$par.random,
        p = pnorm(q = u, mean = 0, sd = exp(log_sigma)),
        alarm = p >= sig.level
      )
      
      if(CI){
        # Calculate the confidence using root-finding
        CI.theta <- sapply(X = 1:(ncol(designMatrix)+1), FUN = function(x) TMB::tmbroot(PoisN, x))
        # Construct nice parameter table
        par <- dplyr::tibble(
          Parameter = c(colnames(designMatrix),"log_sigma"),
          theta = opt$par,
          CI.lwr = CI.theta[1,],
          CI.upr = CI.theta[2,]
        )
      }else{
        # Construct nice parameter table
        par <- dplyr::tibble(
          Parameter = c(colnames(designMatrix),"log_sigma"),
          theta = opt$par,
          se.theta = sqrt(diag(sdRep$cov.fixed))
        )
      }
      
      
      # Combine the results in a tibble
      results <- dplyr::bind_rows(
        results,
        dplyr::tibble(
          ref.date = refDate,
          par = list(par),
          value = opt$value,
          LogS = refPoisN$fn(x = opt$par),
          counts = list(opt$counts),
          convergence = opt$convergence,
          message = opt$message,
          hessian = list(opt$hessian),
          sd.rep = list(sdRep),
          ran.ef = list(ran.ef),
          window.data = list(yWindow)
        )
      )
      
      # Construct parameter guess for next iteration
      theta <- opt$par * 0.7
      
    }else if(model == "PoissonGamma"){
      
      # Construct objective function with derivatives based on a compiled C++ template
      PoisG <- TMB::MakeADFun(
        data = list(y = yWindow$y, n = yWindow$n, X = designMatrix),
        parameters = list(beta = theta[1:ncol(designMatrix)],
                          log_phi_u = theta[-(1:ncol(designMatrix))]),
        hessian = TRUE,
        method = method,
        DLL = model,
        silent = TRUE
        )
      
      # Include lower bound for if 'method' is 'L-BFGS-B'
      if(method == "L-BFGS-B"){
        PoisG$lower <- lower
        PoisG$upper <- upper
      }
      
      # Optimize the function
      opt <- do.call(what = "optim", args = PoisG)
      
      ## Report on the random effects
      sdRep <- TMB::sdreport(PoisG)
      
      # Make a design matrix for the reference data
      refDesign <- model.matrix(object = formula, data = refData)
      
      # Make the function for the reference data
      refPoisG <- TMB::MakeADFun(
        data = list(y = refData$y, n = refData$n, X = refDesign),
        parameters = list(beta = theta[1:ncol(refDesign)],
                          log_phi_u = theta[-(1:ncol(refDesign))]),
        DLL = model,
        silent = TRUE
      )
      
      # Calculate the random effects and related information
      ran.ef <- dplyr::tibble(
        ref.date = refDate,
        ageGroup = refData$ageGroup,
        n = refData$n,
        y = refData$y,
        phi = exp(opt$par[-(1:ncol(refDesign))]),
        lambda = c(exp(refDesign %*% opt$par[1:ncol(refDesign)] - log(n))),
        u = ( y*phi+1 ) / (lambda * phi + 1),
        p = pgamma(q = u, shape = 1/phi, scale = phi),
        alarm = p >= sig.level
      )
      
      if(CI){
        # Calculate the confidence using root-finding
        CI.theta <- sapply(X = 1:(ncol(designMatrix)+1), FUN = function(x) TMB::tmbroot(PoisG, x))
        # Construct nice parameter table
        par <- dplyr::tibble(
          Parameter = c(colnames(designMatrix),"log_phi"),
          theta = opt$par,
          CI.lwr = CI.theta[1,],
          CI.upr = CI.theta[2,]
        )
      }else{
        # Construct nice parameter table
        par <- dplyr::tibble(
          Parameter = c(colnames(designMatrix),"log_phi"),
          theta = opt$par,
          se.theta = sqrt(diag(sdRep$cov.fixed))
        )
      }
      
      # Combine the results in a tibble
      results <- dplyr::bind_rows(
        results,
        dplyr::tibble(
          ref.date = refDate,
          par = list(par),
          value = opt$value,
          LogS = refPoisG$fn(x = opt$par),
          counts = list(opt$counts),
          convergence = opt$convergence,
          message = opt$message,
          hessian = list(opt$hessian),
          sd.rep = list(sdRep),
          ran.ef = list(ran.ef),
          window.data = list(yWindow)
        )
      )
      
      # Construct parameter guess for next iteration
      theta <- opt$par * 0.7
      
    }else{
      stop("Not implemented yet")
    }
    
    if(excludePastOutbreaks == TRUE & sum(ran.ef$alarm) > 0){
      pastOutbreaks <- dplyr::`%>%`(
        dplyr::`%>%`(
          dplyr::`%>%`(
            ran.ef, dplyr::filter(alarm == TRUE)
            ), dplyr::select(Date = ref.date, ageGroup, y, n)
          ), dplyr::bind_rows(pastOutbreaks)
        )
      
      # Add seasonality
      if(seasonality){
        if(period == "month"){
          pastOutbreaks <- dplyr::`%>%`(
            pastOutbreaks,
            dplyr::mutate(periodInYear = as.integer(format(Date, "%m")))
          )  
        }else if(period == "week"){
          pastOutbreaks <- dplyr::`%>%`(
            pastOutbreaks,
            dplyr::mutate(periodInYear = as.integer(format(Date, "%W")))
          )
        }
      }
      
      # Add trend
      if(trend){
        if(period == "month"){
          pastOutbreaks <- dplyr::`%>%`(
            pastOutbreaks,
            dplyr::mutate(t = lubridate::interval(
              Dates[i],
              Date) %/% months(1) - k + 1
            )
          )
        }else if(period == "week"){
          pastOutbreaks <- dplyr::`%>%`(
            pastOutbreaks,
            dplyr::mutate(t = 0)
          )
        }
      }
      
    }
    
  }
  
  return(results)
  
}
