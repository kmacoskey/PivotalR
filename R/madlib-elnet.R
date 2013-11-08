
## ----------------------------------------------------------------------
## Wrapper function for MADlib's elastic_net function
## ----------------------------------------------------------------------

setClass("elnet.madlib")

madlib.elnet <- function (formula, data, family = "gaussian", na.action,
                          alpha = 1, lambda = 0.1, standardize = TRUE,
                          method = "fista", control = list(),
                          glmnet = FALSE, ...)
{
    control <- .validate.method(method, control)
    method <- tolower(method)
    if (method == "sgd") method <- "igd"
    family <- .validate.family(family)
    call <- match.call()

    if (!is(data, "db.obj"))
        stop("madlib.elnet can only be used on a db.obj object, and ",
             deparse(substitute(data)), " is not!")
    origin.data <- data
    .check.madlib.version(data)
    conn.id <- conn.id(data)

    db.str <- (.get.dbms.str(conn.id))$db.str
    if (db.str == "HAWQ")
        stop("Current HAWQ does not support this function!")

    warnings <- .suppress.warnings(conn.id)

    analyzer <- .get.params(formula, data)
    data <- analyzer$data
    params <- analyzer$params
    is.tbl.source.temp <- analyzer$is.tbl.source.temp
    if (!is.null(params$grp.str))
        stop("Grouping calculation is not supported right now!")
    
    tmp <- eval(parse(text = paste("with(data, ",
                      params$origin.dep, ")", sep = "")))
    if (family == "gaussian" &&
        tmp@.col.data_type %in% c("boolean", "text", "varchar"))
        stop("The dependent variable type is not supported ",
             "in this function!")

    tbl.source <- gsub("\"", "", content(data))
    madlib <- schema.madlib(conn.id) # MADlib schema name

    params$ind.str <- gsub("\\[1,", "\\[", params$ind.str)
    tbl.output <- .unique.string()

    if (glmnet && family == "gaussian") {
        y <- scale(eval(parse(text = paste("with(data, ",
                              deparse(params$terms[[2]]), ")",
                              sep = ""))), center = TRUE, scale = TRUE)
        y.ctr <- attr(y, "scaled:center")
        n <- nrow(data)
        y.scl <- attr(y, "scaled:scale") * sqrt((n-1)/n)
        lambda <- lambda / y.scl
        y <- y / sqrt((n-1)/n)
        dep <- y@.expr
    } else {
        dep <- params$dep.str
    }

    if (family == "binomial") dep <- paste("(", dep, ")::boolean", sep = "")
    
    sql <- paste("select ", madlib, ".elastic_net_train('", tbl.source,
                 "', '", tbl.output, "', '", dep, "', '",
                 params$ind.str, "', '", family, "', ", alpha, ", ", lambda,
                 ", ", standardize, ", NULL, '", method, "', '",
                 control$control.str, "', NULL, ", control$max.iter, ", ",
                 control$tolerance, ")", sep = "")

    res <- .get.res(sql, tbl.output, conn.id)
    model <- db.data.frame(tbl.output, conn.id = conn.id, verbose = FALSE)

    if (is.tbl.source.temp) .db.removeTable(tbl.source, conn.id)
    .restore.warnings(warnings)

    ## prepare the result
    rst <- list()
    rst$coef <- as.vector(arraydb.to.arrayr(res$coef_all, "double"))
    
    rows <- gsub("\"", "", params$ind.vars)
    rst$ind.vars <- rows
    col.name <- gsub("\"", "", data@.col.name)
    appear <- data@.appear.name
    for (i in seq_len(length(col.name))) 
        if (col.name[i] != appear[i])
            rows <- gsub(col.name[i], appear[i], rows)
    rows <- gsub("\\((.*)\\)\\[(\\d+)\\]", "\\1[\\2]", rows)
    names(rst$coef) <- rows
    
    rst$intercept <- res$intercept
    names(rst$intercept) <- "(Intercept)"

    rst$glmnet <- glmnet
    if (glmnet && family == "gaussian") {
        rst$intercept <- rst$intercept * y.scl + y.ctr
        rst$coef <- rst$coef * y.scl
        rst$y.scl <- y.scl
    } else
        rst$y.scl <- 1
    
    rst$loglik <- res$log_likelihood
    rst$standardize <- res$standardize
    rst$iter <- res$iteration_run
    rst$ind.str <- params$ind.str
    rst$dummy <- data@.dummy
    rst$dummy.expr <- data@.dummy.expr
    rst$appear <- appear
    rst$terms <- params$terms
    rst$model <- model
    rst$call <- call
    rst$alpha <- alpha
    rst$lambda <- lambda
    rst$method <- method
    rst$family <- family
    class(rst) <- "elnet.madlib"
    rst
}

## ----------------------------------------------------------------------

.validate.family <- function (family)
{
    if (!is.character(family))
        stop("family must be \"gaussian\" or \"binomial\"")
    family <- tolower(family)
    if (! family %in% c("gaussian", "linear", "binomial", "logistic"))
        stop("family must be \"gaussian\" or \"binomial\"")
    if (family == "linear") family <- "gaussian"
    if (family == "logistic") family <- "binomial"
    family
}

## ----------------------------------------------------------------------

.validate.method <- function (method, control)
{
    if (!is.character(method)) stop("method must be \"fista\" or \"igd\"!")
    method <- tolower(method)
    if (!is.list(control)) stop("control must be a list of parameters!")
    if (! method %in% c("fista", "igd"))
        stop("MADlib only supports FISTA and IGD!")
    if (method == "igd" &&
        !all(names(control) %in% c("step.size", "step.decay", "threshold",
                                   "warmup", "warmup.lambdas",
                                   "warmup.lambda.no", "warmup.tolerance",
                                   "parallel", "max.iter", "tolerance")) ||
        method == "fista" &&
        !all(names(control) %in% c("max.stepsize", "eta", "warmup",
                                   "warmup.lambdas", "warmup.lambda.no",
                                   "warmup.tolerance", "use.active.set",
                                   "activeset.tolerance", "random.stepsize",
                                   "max.iter", "tolerance")))
        stop("Some of the control parameters are not supported!")

    names(control) <- gsub("\\.", "_", names(control))

    ## max_iter and tolerance are not in SQL's optimizer_params
    max.iter <- 10000
    tolerance <- 1e-4
    if ("max_iter" %in% names(control)) {
        max.iter <- control$max_iter
        control$max_iter <- NULL
    }
    if ("tolerance" %in% names(control)) {
        tolerance <- control$tolerance
        control$tolerance <- NULL
    }

    nms <- names(control)
    for (i in seq_len(length(names(control)))) {
        if (nms[i] %in% c("warmup", "use.active.set", "random.stepsize")) {
            if (is.logical(control[[i]]))
                control[[i]] <- if (control[[i]]) "t" else "f"
            else
                stop("The parameters warmup, use.active.set and random.stepsize ",
                     "must use TRUE/FALSE!")
        } else if (nms[i] == "warmup.lambdas") {
            control[[i]] <- paste("[", paste(control[[i]], collapse = ", "),
                                  "]", sep = "")
        }
        
    }

    list(control.str = if (is.null(nms) ||
         identical(nms, character(0))) ""
    else paste(nms, " = ", as.character(control),
               sep = "", collapse = ", "), max.iter = max.iter,
         tolerance = tolerance)
}

## ----------------------------------------------------------------------

summary.elnet.madlib <- function (object, ...) object

## ----------------------------------------------------------------------

show.elnet.madlib <- function (object) print(object)

## ----------------------------------------------------------------------

print.elnet.madlib <- function (x,
                                 digits = max(3L, getOption("digits") - 3L),
                                 ...)
{
    cat("\nMADlib Elastic-net Regression Result\n")
    cat("\nCall:\n", paste(deparse(x$call), sep = "\n", collapse = "\n"),
        "\n", sep = "")
    cat("\nCoefficients:\n")
    print(format(x$coef, digits = digits), quote = FALSE)
    cat("\n")
    print(format(x$intercept, digits = digits), quote = FALSE)
    if (x$standardize) std.str <- ""
    else std.str <- " not"
    cat("\nThe independent variables are", std.str,
        " standardized.\n", sep = "")
    cat("The log-likelihood is", format(x$loglik, digits = digits))
    cat("\nThe computation is done in", x$iter, "iterations.\n\n")
}

## ----------------------------------------------------------------------

predict.elnet.madlib <- function (object, newdata, type = "default",
                                   ...)
{
    if (!is(newdata, "db.obj"))
        stop("New data for prediction must be a db.obj!")

    if (!is.character(type) ||
        !tolower(type) %in% c("default", "response"))
        stop("type must be \"default\" or \"response\"!")
    type <- tolower(type)
    
    conn.id <- conn.id(newdata)
    madlib <- schema.madlib(conn.id) # MADlib schema name
    if (is(newdata, "db.data.frame")) {
        tbl <- content(newdata)
        src <- tbl
        parent <- src
        where <- ""
        where.str <- ""
        sort <- list(by = "", order = "", str = "")
    } else {
        if (newdata@.source == newdata@.parent)
            tbl <- newdata@.parent
        else
            tbl <- paste("(", newdata@.parent, ") s", sep = "")
        src <- newdata@.source
        parent <- newdata@.parent
        where <- newdata@.where
        if (where != "") where.str <- paste(" where", where)
        else where.str <- ""
        sort <- newdata@.sort
    }

    if (!is(newdata, "db.data.frame"))
        ind.str <- .replace.col.with.expr(object$ind.str,
                                          names(newdata),
                                          newdata@.expr)
    else
        ind.str <- object$ind.str

    if (object$family == "gaussian") {
        expr <- paste(madlib, ".elastic_net_gaussian_predict(",
                     "(select ", madlib, ".array_scalar_mult(coef_all,",
                      object$y.scl, "::double precision) from ",
                      content(object$model),
                      "), ", object$intercept, ", ", ind.str, ")", sep = "")
        data.type <- "double precision"
        udt.name <- "float8"
    }

    if (object$family == "binomial") {
        if (type == "default") {
            expr <- paste(madlib, ".elastic_net_binomial_predict(",
                          "(select ", madlib, ".array_scalar_mult(coef_all,",
                          object$y.scl, "::double precision) from ",
                          content(object$model), "), ", object$intercept,
                          ", ", ind.str, ")", sep = "")
            data.type <- "boolean"
            udt.name <- "bool"
        } else {
            expr <- paste(madlib, ".elastic_net_binomial_prob(",
                          "(select ", madlib, ".array_scalar_mult(coef_all,",
                          object$y.scl, "::double precision) from ",
                          content(object$model), "), ", object$intercept,
                          ", ", ind.str, ")", sep = "")
            data.type <- "double precision"
            udt.name <- "float8"
        }
    }

    sql <- paste("select ", expr, " as madlib_predict from ",
                 tbl, where.str, sort$str, sep = "")

    if (length(object$dummy) != 0) {
        for (i in seq_len(length(object$dummy))) {
            sql <- gsub(paste("(\"", object$dummy[i], "\"|",
                              object$dummy[i], ")", sep = ""),
                        object$dummy.expr[i], sql)
            expr <- gsub(paste("(\"", object$dummy[i], "\"|",
                               object$dummy[i], ")", sep = ""),
                         object$dummy.expr[i], expr)
        }
    }
    
    new("db.Rquery",
        .content = sql,
        .expr = expr,
        .source = src,
        .parent = parent,
        .conn.id = conn.id(newdata),
        .col.name = "madlib_predict",
        .key = character(0),
        .col.data_type = data.type,
        .col.udt_name = udt.name,
        .where = where,
        .is.factor = FALSE,
        .factor.suffix = "",
        .sort = sort)
}