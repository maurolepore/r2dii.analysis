#' Summaries based on the weight of each loan per sector per year
#'
#' Based on on the weight of each loan per sector per year,
#' `summarize_weighted_production()` and `summarize_weighted_percent_change()`
#' summarize the production and percent-change, respectively.
#'
#' @param data A data frame like the output of [join_ald_scenario()].
#' @param use_credit_limit Logical vector of length 1. `FALSE` defaults to using
#'   the column `loan_size_outstanding`. Set to `TRUE` to instead use the column
#'   `loan_size_credit_limit`.
#' @param ... Variables to group by.
#'
#' @seealso [join_ald_scenario()].
#'
#' @export
#'
#' @section Warning:
#' The percent-change analysis excludes companies with 0 production. percent-change is
#' undefined for companies that have no initial production; including such
#' companies would cause percent-change percentage to be infinite, which is wrong.
#'
#' @family utility functions
#'
#' @return A tibble with the same groups as the input (if any) and columns:
#'   `sector`, `technology`, and `year`; and `weighted_production` or
#'   `weighted_production` for `summarize_weighted_production()` and
#'   `summarize_weighted_percent_change()`, respectively.
#'
#' @examples
#' installed <- requireNamespace("r2dii.data", quietly = TRUE) &&
#'   requireNamespace("r2dii.match", quietly = TRUE)
#' if (!installed) stop("Please install r2dii.match and r2dii.data")
#'
#' library(r2dii.data)
#' library(r2dii.match)
#'
#' master <- loanbook_demo %>%
#'   match_name(ald_demo) %>%
#'   prioritize() %>%
#'   join_ald_scenario(
#'     ald = ald_demo,
#'     scenario = scenario_demo_2020,
#'     region_isos = region_isos_demo
#'   )
#'
#' summarize_weighted_production(master)
#'
#' summarize_weighted_production(master, use_credit_limit = TRUE)
#'
#' summarize_weighted_percent_change(master)
#'
#' summarize_weighted_percent_change(master, use_credit_limit = TRUE)
summarize_weighted_production <- function(data, ..., use_credit_limit = FALSE) {
  summarize_weighted_metric(
    data = data,
    group_dots = rlang::enquos(...),
    use_credit_limit = use_credit_limit,

    .f = add_weighted_loan_production,
    weighted_production = sum(.data$weighted_loan_production)
  )
}

#' @rdname summarize_weighted_production
#' @export
summarize_weighted_percent_change <- function(data, ..., use_credit_limit = FALSE) {
  summarize_weighted_metric(
    data = data,
    group_dots = rlang::enquos(...),
    use_credit_limit = use_credit_limit,

    .f = add_weighted_loan_percent_change,
    weighted_percent_change = mean(.data$weighted_loan_percent_change)
  )
}

summarize_weighted_metric <- function(data,
                                      group_dots,
                                      use_credit_limit,
                                      .f,
                                      ...) {
  data %>%
    .f(use_credit_limit = use_credit_limit) %>%
    group_by(.data$sector, .data$technology, .data$year, !!!group_dots) %>%
    summarize(...) %>%
    # Restore old groups
    group_by(!!!dplyr::groups(data))
}

add_weighted_loan_percent_change <- function(data, use_credit_limit = FALSE) {
  add_weighted_loan_metric(data, use_credit_limit, percent_change = TRUE)
}

add_weighted_loan_production <- function(data, use_credit_limit = FALSE) {
  add_weighted_loan_metric(data, use_credit_limit, percent_change = FALSE)
}

add_weighted_loan_metric <- function(data, use_credit_limit, percent_change) {
  stopifnot(
    is.data.frame(data),
    isTRUE(use_credit_limit) || isFALSE(use_credit_limit)
  )

  loan_size <- paste0(
    "loan_size_", ifelse(use_credit_limit, "credit_limit", "outstanding")
  )

  crucial <- c(
    "id_loan",
    loan_size,
    "production",
    "sector",
    "technology",
    "year"
  )

  if (percent_change) {
    crucial <- c(crucial, "scenario")
  }

  check_crucial_names(data, crucial)
  walk(crucial, ~ check_no_value_is_missing(data, .x))

  if (percent_change) {
    check_zero_initial_production(data)
  }

  old_groups <- dplyr::groups(data)
  data <- ungroup(data)

  distinct_loans_by_sector <- data %>%
    ungroup() %>%
    group_by(.data$sector) %>%
    distinct(.data$id_loan, .data[[loan_size]]) %>%
    check_unique_loan_size_values_per_id_loan()

  total_size_by_sector <- distinct_loans_by_sector %>%
    summarize(total_size = sum(.data[[loan_size]]))

  out <- data
  metric <- "production"
  if (percent_change) {
    out <- add_percent_change(out)
    metric <- "percent_change"
  }

  out %>%
    left_join(total_size_by_sector, by = "sector") %>%
    mutate(
      loan_weight = .data[[loan_size]] / .data$total_size,
      weighted_loan_metric = .data[[metric]] * .data$loan_weight
    ) %>%
    group_by(!!!old_groups) %>%
    rename_metric(metric)
}

add_percent_change <- function(data) {
  data %>%
    inner_join(green_or_brown, by = c("sector", "technology")) %>%
    group_by(.data$sector, .data$year, .data$scenario) %>%
    mutate(sector_production = sum(.data$production)) %>%
    group_by(.data$sector, .data$name_ald) %>%
    arrange(.data$name_ald, .data$year) %>%
    mutate(
      brown_percent_change =
        (.data$production - first(.data$production)) /
          first(.data$production) * 100,
      green_percent_change = (.data$production - first(.data$production)) /
        first(.data$sector_production) * 100
    ) %>%
    mutate(percent_change = dplyr::case_when(
      green_or_brown == "green" ~ green_percent_change,
      green_or_brown == "brown" ~ brown_percent_change
    )) %>%
    select(one_of(c(names(data), "percent_change"))) %>%
    ungroup()
}

check_zero_initial_production <- function(data) {
  companies_with_zero_initial_production <- data %>%
    group_by(.data$technology, .data$name_ald, .data$year) %>%
    arrange(.data$year) %>%
    filter(.data$year == first(.data$year)) %>%
    summarize(production_at_start_year = sum(.data$production)) %>%
    filter(.data$production_at_start_year == 0)

  if (nrow(companies_with_zero_initial_production) > 0L) {
    abort(
      class = "zero_initial_production",
      "No `name_ald` by `technology` can have initial `production` values of 0."
    )
  }

  invisible(data)
}

check_unique_loan_size_values_per_id_loan <- function(data) {
  dups <- data %>%
    group_by(.data$sector, .data$id_loan) %>%
    mutate(is_duplicated = any(duplicated(.data$id_loan))) %>%
    ungroup() %>%
    filter(.data$is_duplicated)

  if (nrow(dups) > 0L) {
    abort(
      class = "multiple_loan_size_values_by_id_loan",
      "Every `id_loan` by `sector` must have unique `loan_size*` values."
    )
  }

  invisible(data)
}

rename_metric <- function(out, metric) {
  new_name <- paste0("weighted_loan_", metric)
  newnames <- sub("weighted_loan_metric", new_name, names(out))
  out <- rlang::set_names(out, newnames)

  out
}
