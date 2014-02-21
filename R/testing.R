## The environment that contains all environment variables
.testing.env <- new.env(parent = getNamespace(.this.pkg.name))

## ----------------------------------------------------------------------

.get.param.inputs <- function(param.names = c(".port", ".dbname"),
                              reset = FALSE)
{
    testing.vars <- ls(.testing.env, all.names = TRUE)
    if (reset || any(!param.names %in% testing.vars)) {
        cat("\n")
        for (i in param.names)
            if (reset || !i %in% testing.vars) {
                .testing.env[[i]] <- readline(paste(i, "? ", sep = ""))
            }
    }
}

## ----------------------------------------------------------------------

## skip an "expect_that" test if cond is TRUE
skip_if <- function(cond, test.expr)
{
    expr <- deparse(substitute(test.expr))
    l <- sum(sapply(gregexpr("expect_that\\(", expr), function(s) sum(s>0)))
    if (cond) {
        if (.localVars$test.reporter %in% c("summary", "minimal"))
            for (i in seq_len(l)) cat(testthat::colourise(",", fg = "purple"))
        else if (.localVars$test.reporter == "tap") {
            for (i in seq_len(l)) {
                .localVars$test.skip <- .localVars$test.skip + 1
                cmd <- paste("test_that(\"SKIP this test ", .localVars$test.skip,
                             "\", expect_that(TRUE, is_true()))", sep = "")
                eval(parse(text = cmd))
            }
        }
    } else {
        test.expr
    }
}

## ----------------------------------------------------------------------

test <- function(path = "tests", filter = NULL,
                 reporter = c("summary", "tap", "minimal", "stop"),
                 env.file = NULL, env.vars = list(),
                 clean.test.env = FALSE, run = c("tests", "examples", "both"))
{
    run <- match.arg(run)

    if (path == "tests")
        test_path <- system.file(path, package = .this.pkg.name)
    else
        test_path <- path

    if (test_path == "")
        stop("You need to use --install-tests option to install ",
             "the tests when you are installing PivotalR!")

    ## connections before testing
    ## so that we can close all un-closed connections after testing
    if (identical(.localVars$conn.id, integer(0)))
        origin.conn.id <- integer(0)
    else
        origin.conn.id <- .localVars$conn.id[,1]

    ## close unclosed connection opened during testing
    cleanup.conn <- function() {
        if (identical(.localVars$conn.id, integer(0)))
            curr.conn.id <- integer(0)
        else
            curr.conn.id <- .localVars$conn.id[,1]
        for (i in setdiff(curr.conn.id, origin.conn.id))
            db.disconnect(conn.id = i, verbose = FALSE, force = TRUE)
    }

    reporter <- match.arg(reporter)
    .localVars$test.reporter <- reporter
    .localVars$test.skip <- 0

    installed.pkgs <- .get.installed.pkgs()
    if (! "testthat" %in% installed.pkgs) {
        message("Package 'testthat' is going to be installed!")
        install.packages(pkgs = "testthat")
        if (! "testthat" %in% .get.installed.pkgs())
            stop("The package 'testthat' could not be installed!")
    }
    library(testthat)

    reporter <- eval(parse(text = "testthat:::find_reporter(reporter)"))

    if (!is.null(env.file))
        .fill.testing.env(env.file)
    else if (length(env.vars) > 0)
        for (var in names(env.vars))
            assign(var, env.vars[[var]], envir = .testing.env)

    if (clean.test.env)
        for (var in ls(.testing.env, all.names = TRUE))
            rm(var, envir = .testing.env)

    if (run == "examples" || run == "both") {
        cat(testthat::colourise("Running examples in the user doc ---------\n",
                                fg = "light blue"))
        tryCatch(.run.doc.example(reporter, filter),
                 interrupt = function(cond) {
                     cleanup.conn()
                     unlink(.localVars$example.tmppath, recursive = TRUE)
                     rm("example.tmppath", envir = .localVars)
                 })
        cleanup.conn()
        unlink(.localVars$example.tmppath, recursive = TRUE)
        rm("example.tmppath", envir = .localVars)
    }

    if (run == "tests" || run == "both") {
        cat(testthat::colourise("Running tests ----------------------------\n",
                                fg = "light blue"))
        tryCatch(testthat::test_dir(test_path, reporter = reporter,
                                    env = .testing.env, filter = filter),
                 interrupt = function(cond) cleanup.conn())
        cleanup.conn()
    }

    if (reporter$failed) {
        stop("Test failures", call. = FALSE)
    }
    invisible()
}

## ----------------------------------------------------------------------

## Given a file, put all values in the file into testing.env
## Each line of the file should be a key : value pair
.fill.testing.env <- function(env.file)
{
    con <- file(env.file)
    params <- readLines(con)
    close(con)
    for (line in params) {
        if (grepl("^\\s*#", line)) next # allow '#' to start a comment
        words <- .strip(strsplit(line, ":")[[1]])
        if (length(words) >= 2) {
            key <- .strip(strsplit(words[1], "#")[[1]][1])
            value <- .strip(strsplit(words[2], "#")[[1]][1])
            assign(key, value, envir = .testing.env)
        }
    }
}

## ----------------------------------------------------------------------

## Used for tests, no error during execution
has_no_error <- function ()
{
    function(expr) {
        res <- try(force(expr), TRUE)
        has_error <- inherits(res, "try-error")
        if (has_error) {
            return (eval(parse(
                text = paste("expectation(FALSE,",
                paste("'code generated an error: ",
                      as.character(res), "'", sep = "")))))
        }
        eval(parse(text = "expectation(TRUE, '')"))
    }
}

## ----------------------------------------------------------------------

## run doc example
.run.doc.example <- function(reporter, filter)
{
    library(tools)
    x <- tools::Rd_db(.this.pkg.name)

    outpath <- paste("/tmp/", .unique.string(), "/", sep = "")
    dir.create(outpath, recursive = TRUE)
    .localVars$example.tmppath <- outpath

    ## loop over all Rd files
    for (i in seq_along(x)) {
        filename <- gsub(".*/man/(.*\\.Rd)", "\\1", names(x)[i])
        y <- eval(parse(text = as.character(x[i])))
        for (j in seq_along(y)) {
            z <- unlist(y[[j]])
            pa <- grepl("%%\\s+@test", z)
            if (sum(pa) == 0) next # not an example to run
            ## params needed
            params <- gsub("%%\\s+@test\\s+(\\S+)\\s+.*", "\\1", z[pa])

            outfile <- paste(outpath, "test-", filename, ".r", sep = "")
            con <- file(outfile, "w")
            cat("context('Doc example in ", filename, "')\n",
                sep = "", file = con)
            cat(".get.param.inputs(c(",
                paste("'", params, "'", collapse = ",", sep = ""),
                "))\n\n", sep = "", file = con)

            cat("test_that('Example in ", filename, "', {expect_that({",
                sep = "", file = con)
            for (line in z[!pa]) cat(line, file = con)
            cat("}, has_no_error())})", file = con)
            close(con)
        }
    }

    testthat::test_dir(outpath, reporter = reporter,
                       env = .testing.env, filter = filter)

    invisible()
}