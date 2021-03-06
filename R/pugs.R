#' @title Classify new samples using an Ensemble of Classifier Chains
#' @description Uses a trained ECC and Gibbs sampling to predict labels for new
#'   samples. \code{.f} must return a matrix of probabilities, one row for each
#'   observation in \code{newdata}.
#' @param object An object of type \code{ECC} returned by \code{\link{ecc}()}.
#' @param newdata A data frame or matrix of features. Must be the same form as
#' the one used with \code{\link{ecc}()}.
#' @param n.iters Number of iterations of the Gibbs sampler.
#' @param burn.in Number of iterations for adaptation (burn-in).
#' @param thin Thinning interval.
#' @param run_parallel Logical flag for utilizing multicore capabilities of the
#'   system.
#' @param silent Logical flag indicating whether to have a progress bar (if
#'   the 'progress' package is installed) or print progress messages to console.
#' @param .f User-supplied prediction function that corresponds to the type of
#' classifier that was trained in the \code{\link{ecc}()} step. See Details.
#' @param ... additional arguments to pass to \code{.f}.
#' @return An object of class \code{PUGS} containing: \itemize{
#'  \item \code{y_labels} : inherited from \code{object}
#'  \item \code{preds} : A burnt-in, thinned multi-dimensional array of predictions.
#' }
#' @details Getting the prediction function correct is very important here.
#'   Since this package is a wrapper that can use any classification algorithm
#'   as its base classifier, certain assumptions have been made. We assume that
#'   the prediction function can return a data.frame or matrix of probabilities
#'   with two columns: "0" and "1" because \code{\link{ecc}()} trains on a
#'   factor of "0"s and "1"s for more universal consistency.
#' @examples
#' x <- movies_train[, -(1:3)]
#' y <- movies_train[, 1:3]
#' 
#' model_glm <- ecc(x, y, m = 1, .f = glm.fit, family = binomial(link = "logit"))
#' 
#' predictions_glm <- predict(model_glm, movies_test[, -(1:3)],
#' .f = function(glm_fit, newdata) {
#' 
#'   # Credit for writing the prediction function that works
#'   # with objects created through glm.fit goes to Thomas Lumley
#'   
#'   eta <- as.matrix(newdata) %*% glm_fit$coef
#'   output <- glm_fit$family$linkinv(eta)
#'   colnames(output) <- "1"
#'   return(output)
#'   
#' }, n.iters = 10, burn.in = 0, thin = 1)
#'
#' \dontrun{
#' 
#' model_c50 <- ecc(x, y, .f = C50::C5.0)
#' predictions_c50 <- predict(model_c50, movies_test[, -(1:3)],
#'                            n.iters = 10, burn.in = 0, thin = 1,
#'                            .f = C50::predict.C5.0, type = "prob")
#'   
#' model_rf <- ecc(x, y, .f = randomForest::randomForest)
#' predictions_rf <- predict(model_rf, movies_test[, -(1:3)],
#'                           n.iters = 1000, burn.in = 100, thin = 10,
#'                           .f = function(rF, newdata) {
#'                             randomForest:::predict.randomForest(rF, newdata, type = "prob")
#'                           })
#' }
#' @export
predict.ECC <- function(object, newdata,
                        n.iters = 300, burn.in = 100, thin = 2,
                        run_parallel = FALSE, silent = TRUE,
                        .f = NULL, ...)
{
  m <- length(object$fits)
  L <- length(object$y_labels)
  n <- nrow(newdata)
  ecc_preds <- unlist(parallel::mclapply(1:m, function(k) {
    # Initialize
    cc_preds <- array(0, c(n, L, burn.in + n.iters))
    cc_preds[,,1] <- matrix(stats::rbinom(n * L, 1, prob = 0.5), nrow = n)
    if (!silent & !run_parallel) {
      if (requireNamespace("progress", quietly = TRUE)) {
        pb <- progress::progress_bar$new(total = burn.in + n.iters)
      } else {
        message("'progress' package not installed; using simple updates:")
        cat(sprintf("Model %.0f finished Iteration 1\n", k))
      }
    }
    # Iterate
    for ( i in 2:(burn.in + n.iters) ) {
      elapsed <- system.time({
        for ( l in 1:L ) {
          # Assemble a features matrix by augmenting supplied features
          # with predicted labels using the most recent predictions.
          iter_idx <- i - ((1:L) >= l)
          temp <- matrix(0, nrow = n, ncol = L)
          for ( j in 1:length(iter_idx) ) {
            temp[, j] <- cc_preds[, j, iter_idx[j]]
          }
          colnames(temp) <- paste0('label_', 1:L)
          augmented_newdata <- cbind(newdata, temp[, -l])
          # Draw samples of predictions
          predictions <- .f(object$fits[[k]][[l]], augmented_newdata, ...)[, "1"]
          cc_preds[, l, i] <- vapply(predictions, FUN = function(p) {
                                       return(stats::rbinom(n = 1, size = 1, prob = p))
                                     }, FUN.VALUE = 1, USE.NAMES = FALSE)
        }
      })['elapsed']
      if (!silent) {
        if (requireNamespace("progress", quietly = TRUE)) {
          pb$tick()
        } else {
          cat(sprintf("Model %.0f finished Iteration %.0f (took %.3f seconds) : %.2f%% done\n",
                      k, i, elapsed, 100 * i / (burn.in + n.iters)))
        }
      }
    }
    return(cc_preds)
  }, mc.cores = ifelse(Sys.info()[['sysname']] == "Windows" || !run_parallel, 1, parallel::detectCores())))
  ecc_preds <- array(ecc_preds, dim = c(n, L, n.iters, m),
                     dimnames = list("Instances" = NULL,
                                     "Labels" = NULL,
                                     "Iterations" = NULL,
                                     "Models" = NULL))
  return(structure(list(y_labels = object$y_labels, preds = ecc_preds), class = "PUGS"))
}

#' @title Gather samples of predictions
#' @description Collapses the multi-label predictions across sets of classifier
#'   chains and iterations into a single set of predictions, either binary or
#'   probabilistic.
#' @param object A \code{pugs} object generated by \code{\link{predict.ECC}}.
#' @param ... \code{type = "prob"} for probabilistic predictions,
#' \code{type = "class"} for binary (0/1) predictions
#' @return A matrix of predictions.
#' @examples
#' x <- movies_train[, -(1:3)]
#' y <- movies_train[, 1:3]
#' 
#' model_glm <- ecc(x, y, m = 1, .f = glm.fit, family = binomial(link = "logit"))
#' 
#' predictions_glm <- predict(model_glm, movies_test[, -(1:3)],
#' .f = function(glm_fit, newdata) {
#' 
#'   # Credit for writing the prediction function that works
#'   # with objects created through glm.fit goes to Thomas Lumley
#'   
#'   eta <- as.matrix(newdata) %*% glm_fit$coef
#'   output <- glm_fit$family$linkinv(eta)
#'   colnames(output) <- "1"
#'   return(output)
#'   
#' }, n.iters = 10, burn.in = 0, thin = 1)
#' 
#' summary(predictions_glm, movies_test[, 1:3])
#' 
#' \dontrun{
#' 
#' model_c50 <- ecc(x, y, .f = C50::C5.0)
#' predictions_c50 <- predict(model_c50, movies_test[, -(1:3)],
#'                            n.iters = 10, burn.in = 0, thin = 1,
#'                            .f = C50::predict.C5.0, type = "prob")
#' summary(predictions_c50, movies_test[, 1:3])
#'   
#' model_rf <- ecc(x, y, .f = randomForest::randomForest)
#' predictions_rf <- predict(model_rf, movies_test[, -(1:3)],
#'                           n.iters = 10, burn.in = 0, thin = 1,
#'                           .f = function(rF, newdata){
#'                             randomForest:::predict.randomForest(rF, newdata, type = "prob")
#'                           })
#' summary(predictions_rf, movies_test[, 1:3])
#' }
#' @export
summary.PUGS <- function(object, ...)
{
  if (length(dim(object$preds)) != 4) {
    stop("object should contain an instances \u00d7 labels \u00d7 iterations \u00d7 models array")
  }
  type <- list(...)$type
  if ( is.null(type) ) {
    type <- "class"
  }
  if (!(type %in% c("class", "prob"))) {
    stop("type should be either 'class' or 'prob'")
  }
  if ( type == "class" ) {
    majority <- function(y) { return(1 * ((sum(y) / length(y)) > 0.5)) }
    output <- apply(apply(object$preds, c(1, 2, 4), majority), c(1, 2), majority)
  } else {
    output <- apply(apply(object$preds, c(1, 2, 4), function(y) { return(sum(y)/length(y)) } ), c(1, 2), mean)
  }
  colnames(output) <- object$y_labels
  return(output)
}

#' @title Assess multi-label prediction accuracy
#' @description Computes a variety of accuracy metrics for multi-label
#'   predictions. 
#' @param object A \code{PUGS} object generated by \code{\link{predict.ECC}}.
#' @param y A matrix of the same form as the one used with
#' \code{\link{ecc}}.
#' @return A variety of multi-label classification accuracy measurements.
#' @examples
#' x <- movies_train[, -(1:3)]
#' y <- movies_train[, 1:3]
#' 
#' model_glm <- ecc(x, y, m = 1, .f = glm.fit, family = binomial(link = "logit"))
#' 
#' predictions_glm <- predict(model_glm, movies_test[, -(1:3)],
#' .f = function(glm_fit, newdata) {
#' 
#'   # Credit for writing the prediction function that works
#'   # with objects created through glm.fit goes to Thomas Lumley
#'   
#'   eta <- as.matrix(newdata) %*% glm_fit$coef
#'   output <- glm_fit$family$linkinv(eta)
#'   colnames(output) <- "1"
#'   return(output)
#'   
#' }, n.iters = 10, burn.in = 0, thin = 1)
#' 
#' validate_pugs(predictions_glm, movies_test[, 1:3])
#' 
#' \dontrun{
#' 
#' model_c50 <- ecc(x, y, .f = C50::C5.0)
#' predictions_c50 <- predict(model_c50, movies_test[, -(1:3)],
#'                            n.iters = 10, burn.in = 0, thin = 1,
#'                            .f = C50::predict.C5.0, type = "prob")
#' validate_pugs(predictions_c50, movies_test[, 1:3])
#'   
#' model_rf <- ecc(x, y, .f = randomForest::randomForest)
#' predictions_rf <- predict(model_rf, movies_test[, -(1:3)],
#'                           n.iters = 10, burn.in = 0, thin = 1,
#'                           .f = function(rF, newdata){
#'                             randomForest:::predict.randomForest(rF, newdata, type = "prob")
#'                           })
#' validate_pugs(predictions_rf, movies_test[, 1:3])
#' }
#' @export
validate_pugs <- function(object, y)
{
  if (class(object) != "PUGS") {
    stop("can only operate on multi-label predictions made using Gibbs sampling (PUGS class) objects")
  }
  if ( !is.matrix(y) ) {
    y <- as.matrix(y)
  }
  if ( dim(object$preds)[1] != nrow(y) | dim(object$preds)[2] != ncol(y) ) {
    stop("prediction set and test set must have the same number of observations (instances) and classes (labels)")
  }
  y_hat <- summary(object, type = "prob") # y_hat is the probability that y = 1
  y_hat <- y_hat + 1e-7 * (y_hat == 0) - 1e-7 * (y_hat == 1) # so we don't run into problems with log
  log_loss <- -mean(as.numeric((y * log(y_hat)) + ((1-y) * log(1 - y_hat))))
  y_hat <- summary(object, type = "class")
  safe_mean <- function(x) {
    if (any(is.nan(x))) {
      message("NaNs detected when computing F-scores. This is caused by observations (instances) which do not have any labels. These obs. have been removed from F-score calculation, so we recommend placing heavier emphasis on other accuracy metrics.")
      return(mean(x[!is.nan(x)]))
    }
    return(mean(x))
  }
  return(data.frame("Logarithmic Loss" = log_loss,
                    # ^ logarithmic loss provides a steep penalty for predictions
                    #   that are both confident and wrong
                    "Exact Match Ratio" = mean(apply(y_hat == y, 1, all)),
                    # ^ average per-instance exact classification
                    "Labelling F-score" = safe_mean(apply(((y_hat == 1) & (y == 1)), 1, sum)/apply(((y_hat == 1) | (y == 1)), 1, sum)),
                    # ^ average per-instance classification with partial matches
                    "Retrieval F-score" = safe_mean(apply(((y_hat==1) & (y==1)), 2, sum)/apply(((y_hat==1) | (y==1)), 2, sum)),
                    # ^ average per-label classification with partial matches
                    "Hamming Loss" = mean(as.numeric(y_hat != y)),
                    # ^ average per-example per-class total error
                    stringsAsFactors = FALSE))
}
