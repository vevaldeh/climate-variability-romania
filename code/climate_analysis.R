# ============================================================
# Statistical Analysis of Climate Variability in Romania
# Bachelor's Dissertation | 1995-2024
# Author: Oana - Viviana Scarlat
#
# This script reproduces the main statistical analyses from the
# dissertation directly from the Excel workbook used in the project.
#
# Main analyses:
#   1. National annual mean-temperature series
#   2. OLS linear trend model
#   3. Mann-Kendall trend test
#   4. Welch comparison: 1995-2009 vs 2010-2024
#   5. OLS residual diagnostics
#   6. Newey-West robust standard errors
#   7. Regional Kruskal-Wallis tests
#   8. Regional period comparisons
#   9. Seasonal monthly-profile comparison
#  10. Paired-samples t-test for monthly temperature profiles
#
# The original dissertation used R, Microsoft Excel and ArcGIS Pro.
# Some seasonal calculations were originally performed in Excel;
# they are reproduced here in R to make the GitHub version more
# transparent and reproducible.
# ============================================================


# ------------------------------------------------------------
# 1. Required packages
# ------------------------------------------------------------

required_packages <- c(
  "readxl",
  "Kendall",
  "tseries",
  "lmtest",
  "sandwich"
)

missing_packages <- required_packages[
  !vapply(
    required_packages,
    requireNamespace,
    logical(1),
    quietly = TRUE
  )
]

if (length(missing_packages) > 0) {
  stop(
    paste0(
      "Missing required packages: ",
      paste(missing_packages, collapse = ", "),
      "\nInstall them before running the script, for example:\n",
      "install.packages(c(",
      paste(sprintf('"%s"', missing_packages), collapse = ", "),
      "))"
    )
  )
}


# ------------------------------------------------------------
# 2. Locate project files
# ------------------------------------------------------------

data_candidates <- c(
  file.path("data", "Date_licenta.xlsx"),
  "Date_licenta.xlsx",
  file.path("..", "data", "Date_licenta.xlsx"),
  file.path("..", "Date_licenta.xlsx")
)

existing_data_files <- data_candidates[file.exists(data_candidates)]

if (length(existing_data_files) == 0) {
  stop(
    paste(
      "Date_licenta.xlsx was not found.",
      "Place it either in the repository root or in a data/ folder."
    )
  )
}

data_file <- existing_data_files[1]

repo_root <- if (grepl("^\\.\\./", data_file)) ".." else "."
output_dir <- file.path(repo_root, "outputs")

if (!dir.exists(output_dir)) {
  dir.create(output_dir, recursive = TRUE)
}


# ------------------------------------------------------------
# 3. Validate workbook structure
# ------------------------------------------------------------

required_sheets <- c(
  "Anual 1995-2010",
  "Anual 2011-2024",
  "Lunar 1995-2010",
  "Lunar 2011-2024",
  "Regiuni 1995-2010",
  "Regiuni 2011-2024"
)

available_sheets <- readxl::excel_sheets(data_file)

missing_sheets <- setdiff(required_sheets, available_sheets)

if (length(missing_sheets) > 0) {
  stop(
    paste0(
      "The workbook is missing the following required sheets: ",
      paste(missing_sheets, collapse = ", ")
    )
  )
}


# ------------------------------------------------------------
# 4. Helper functions
# ------------------------------------------------------------

# Extract one annual metric from the workbook's pivot-style sheets.
# The first column contains geographical units and metric labels,
# while the remaining columns contain yearly values.

parse_annual_metric <- function(sheet_name, metric_label) {

  raw <- readxl::read_excel(
    data_file,
    sheet = sheet_name,
    col_names = FALSE
  )

  raw <- as.data.frame(raw, stringsAsFactors = FALSE)

  labels <- trimws(as.character(raw[[1]]))

  year_values <- suppressWarnings(
    as.integer(
      unlist(
        raw[2, -1, drop = FALSE],
        use.names = FALSE
      )
    )
  )

  valid_year_positions <- which(!is.na(year_values))
  years <- year_values[valid_year_positions]

  metric_rows <- which(labels == metric_label)

  if (length(metric_rows) == 0) {
    stop(
      paste0(
        "Metric '",
        metric_label,
        "' was not found in sheet '",
        sheet_name,
        "'."
      )
    )
  }

  # In the pivot-style workbook, the geographical unit appears once
  # above a block of several metrics (mean temperature, maximum
  # temperature, minimum temperature, precipitation and wind).
  # Therefore, for metrics other than the first one, the area name is
  # not necessarily on the immediately preceding row. Search upwards
  # until the nearest non-metric label is found.

  find_area_name <- function(row_index) {

    candidate_row <- row_index - 1

    while (
      candidate_row >= 1 &&
      (
        is.na(labels[candidate_row]) ||
        labels[candidate_row] == "" ||
        grepl("^Average of ", labels[candidate_row])
      )
    ) {
      candidate_row <- candidate_row - 1
    }

    if (candidate_row < 1) {
      stop(
        paste0(
          "Could not identify the geographical unit for metric '",
          metric_label,
          "' in sheet '",
          sheet_name,
          "'."
        )
      )
    }

    labels[candidate_row]
  }

  result <- do.call(
    rbind,
    lapply(metric_rows, function(row_index) {

      area_name <- find_area_name(row_index)

      values <- suppressWarnings(
        as.numeric(
          unlist(
            raw[
              row_index,
              valid_year_positions + 1,
              drop = FALSE
            ],
            use.names = FALSE
          )
        )
      )

      data.frame(
        area = area_name,
        year = years,
        value = values,
        stringsAsFactors = FALSE
      )
    })
  )

  result <- result[
    !is.na(result$area) &
      result$area != "" &
      !is.na(result$year) &
      !is.na(result$value),
  ]

  rownames(result) <- NULL
  result
}


# Extract county-level monthly mean temperatures.
# Years are shown once per block in row 2 and months in row 3,
# so the function fills the year forward across each monthly block.

parse_monthly_mean_temperature <- function(sheet_name) {

  raw <- readxl::read_excel(
    data_file,
    sheet = sheet_name,
    col_names = FALSE
  )

  raw <- as.data.frame(raw, stringsAsFactors = FALSE)

  labels <- trimws(as.character(raw[[1]]))

  year_labels <- as.character(
    unlist(
      raw[2, -1, drop = FALSE],
      use.names = FALSE
    )
  )

  month_labels <- as.character(
    unlist(
      raw[3, -1, drop = FALSE],
      use.names = FALSE
    )
  )

  year_by_column <- rep(NA_integer_, length(year_labels))
  current_year <- NA_integer_

  for (i in seq_along(year_labels)) {

    label <- year_labels[i]

    if (!is.na(label) && nzchar(trimws(label))) {

      year_match <- regexpr(
        "(19|20)[0-9]{2}",
        label,
        perl = TRUE
      )

      if (year_match[1] != -1) {
        current_year <- as.integer(
          regmatches(label, year_match)
        )
      }
    }

    year_by_column[i] <- current_year
  }

  month_number <- match(month_labels, month.name)

  valid_positions <- which(
    !is.na(year_by_column) &
      !is.na(month_number)
  )

  metric_rows <- which(
    labels == "Average of Temp Medii"
  )

  result <- do.call(
    rbind,
    lapply(metric_rows, function(row_index) {

      county_name <- labels[row_index - 1]

      values <- suppressWarnings(
        as.numeric(
          unlist(
            raw[
              row_index,
              valid_positions + 1,
              drop = FALSE
            ],
            use.names = FALSE
          )
        )
      )

      data.frame(
        county = county_name,
        year = year_by_column[valid_positions],
        month = month_number[valid_positions],
        mean_temperature = values,
        stringsAsFactors = FALSE
      )
    })
  )

  result <- result[
    !is.na(result$county) &
      result$county != "" &
      !is.na(result$year) &
      !is.na(result$month) &
      !is.na(result$mean_temperature),
  ]

  rownames(result) <- NULL
  result
}


# ------------------------------------------------------------
# 5. Build the national annual temperature series
# ------------------------------------------------------------

county_temp_1995_2010 <- parse_annual_metric(
  "Anual 1995-2010",
  "Average of Temp Medii"
)

county_temp_2011_2024 <- parse_annual_metric(
  "Anual 2011-2024",
  "Average of Temp Medii"
)

county_annual_temperature <- rbind(
  county_temp_1995_2010,
  county_temp_2011_2024
)

names(county_annual_temperature)[
  names(county_annual_temperature) == "area"
] <- "county"

names(county_annual_temperature)[
  names(county_annual_temperature) == "value"
] <- "mean_temperature"


# The dissertation's national series is reproduced as the
# arithmetic mean of the 42 territorial units (41 counties + Bucharest).

national_annual <- aggregate(
  mean_temperature ~ year,
  data = county_annual_temperature,
  FUN = mean,
  na.rm = TRUE
)

national_annual <- national_annual[
  order(national_annual$year),
]

# The dissertation used national values rounded to two decimals
# in the R analysis. Rounding here reproduces those published results.

national_annual$mean_temperature <- round(
  national_annual$mean_temperature,
  2
)

rownames(national_annual) <- NULL

cat("\n============================================\n")
cat("NATIONAL ANNUAL TEMPERATURE SERIES\n")
cat("============================================\n")
print(national_annual)


# ------------------------------------------------------------
# 6. OLS linear trend model
# ------------------------------------------------------------

ols_model <- lm(
  mean_temperature ~ year,
  data = national_annual
)

ols_summary <- summary(ols_model)

annual_trend <- unname(
  coef(ols_model)["year"]
)

decadal_trend <- annual_trend * 10

cat("\n============================================\n")
cat("OLS LINEAR TREND MODEL\n")
cat("============================================\n")
print(ols_summary)

cat(
  "\nEstimated annual trend:",
  round(annual_trend, 5),
  "°C/year\n"
)

cat(
  "Estimated decadal trend:",
  round(decadal_trend, 3),
  "°C/decade\n"
)


# ------------------------------------------------------------
# 7. Mann-Kendall trend test
# ------------------------------------------------------------

mann_kendall_test <- Kendall::MannKendall(
  national_annual$mean_temperature
)

cat("\n============================================\n")
cat("MANN-KENDALL TREND TEST\n")
cat("============================================\n")
print(mann_kendall_test)


# ------------------------------------------------------------
# 8. Welch comparison: 1995-2009 vs 2010-2024
# ------------------------------------------------------------

period_1995_2009 <- subset(
  national_annual,
  year >= 1995 & year <= 2009
)$mean_temperature

period_2010_2024 <- subset(
  national_annual,
  year >= 2010 & year <= 2024
)$mean_temperature

mean_1995_2009 <- mean(period_1995_2009)
mean_2010_2024 <- mean(period_2010_2024)
period_difference <- mean_2010_2024 - mean_1995_2009

welch_test <- t.test(
  period_2010_2024,
  period_1995_2009,
  var.equal = FALSE
)

cat("\n============================================\n")
cat("WELCH TWO-SAMPLE T-TEST\n")
cat("============================================\n")

cat(
  "Mean temperature, 1995-2009:",
  round(mean_1995_2009, 3),
  "°C\n"
)

cat(
  "Mean temperature, 2010-2024:",
  round(mean_2010_2024, 3),
  "°C\n"
)

cat(
  "Difference:",
  round(period_difference, 3),
  "°C\n\n"
)

print(welch_test)


# ------------------------------------------------------------
# 9. OLS residual diagnostics
# ------------------------------------------------------------

ols_residuals <- residuals(ols_model)

jarque_bera_test <- tseries::jarque.bera.test(
  ols_residuals
)

durbin_watson_test <- lmtest::dwtest(
  ols_model
)

breusch_pagan_test <- lmtest::bptest(
  ols_model
)

cat("\n============================================\n")
cat("OLS RESIDUAL DIAGNOSTICS\n")
cat("============================================\n")

cat("\nJarque-Bera test:\n")
print(jarque_bera_test)

cat("\nDurbin-Watson test:\n")
print(durbin_watson_test)

cat("\nBreusch-Pagan test:\n")
print(breusch_pagan_test)


# ------------------------------------------------------------
# 10. Newey-West robust inference
# ------------------------------------------------------------

newey_west_results <- lmtest::coeftest(
  ols_model,
  vcov. = sandwich::NeweyWest(ols_model)
)

cat("\n============================================\n")
cat("NEWEY-WEST ROBUST COEFFICIENT TEST\n")
cat("============================================\n")
print(newey_west_results)


# ------------------------------------------------------------
# 11. Build regional annual dataset
# ------------------------------------------------------------

regional_temp_1995_2010 <- parse_annual_metric(
  "Regiuni 1995-2010",
  "Average of Temp Max"
)

regional_temp_2011_2024 <- parse_annual_metric(
  "Regiuni 2011-2024",
  "Average of Temp Max"
)

regional_precip_1995_2010 <- parse_annual_metric(
  "Regiuni 1995-2010",
  "Average of Precipitatii"
)

regional_precip_2011_2024 <- parse_annual_metric(
  "Regiuni 2011-2024",
  "Average of Precipitatii"
)

regional_temperature <- rbind(
  regional_temp_1995_2010,
  regional_temp_2011_2024
)

regional_precipitation <- rbind(
  regional_precip_1995_2010,
  regional_precip_2011_2024
)

names(regional_temperature) <- c(
  "region",
  "year",
  "max_temperature"
)

names(regional_precipitation) <- c(
  "region",
  "year",
  "daily_precipitation"
)

regional_data <- merge(
  regional_temperature,
  regional_precipitation,
  by = c("region", "year"),
  all = TRUE
)

regional_data <- regional_data[
  order(regional_data$region, regional_data$year),
]

# The original R analysis used values rounded to two decimals.

regional_data$max_temperature <- round(
  regional_data$max_temperature,
  2
)

regional_data$daily_precipitation <- round(
  regional_data$daily_precipitation,
  2
)

regional_data$region <- factor(
  regional_data$region
)

rownames(regional_data) <- NULL


# ------------------------------------------------------------
# 12. Kruskal-Wallis regional tests
# ------------------------------------------------------------

kruskal_temperature <- kruskal.test(
  max_temperature ~ region,
  data = regional_data
)

kruskal_precipitation <- kruskal.test(
  daily_precipitation ~ region,
  data = regional_data
)

cat("\n============================================\n")
cat("KRUSKAL-WALLIS REGIONAL TESTS\n")
cat("============================================\n")

cat("\nMaximum temperature:\n")
print(kruskal_temperature)

cat("\nDaily precipitation:\n")
print(kruskal_precipitation)


# ------------------------------------------------------------
# 13. Regional comparison between the two periods
# ------------------------------------------------------------

regional_data$period <- ifelse(
  regional_data$year <= 2009,
  "1995-2009",
  "2010-2024"
)

regional_temperature_summary <- aggregate(
  max_temperature ~ region + period,
  data = regional_data,
  FUN = mean,
  na.rm = TRUE
)

regional_precipitation_summary <- aggregate(
  daily_precipitation ~ region + period,
  data = regional_data,
  FUN = mean,
  na.rm = TRUE
)


temperature_old <- subset(
  regional_temperature_summary,
  period == "1995-2009",
  select = c(region, max_temperature)
)

temperature_new <- subset(
  regional_temperature_summary,
  period == "2010-2024",
  select = c(region, max_temperature)
)

names(temperature_old)[2] <- "temp_1995_2009"
names(temperature_new)[2] <- "temp_2010_2024"


precipitation_old <- subset(
  regional_precipitation_summary,
  period == "1995-2009",
  select = c(region, daily_precipitation)
)

precipitation_new <- subset(
  regional_precipitation_summary,
  period == "2010-2024",
  select = c(region, daily_precipitation)
)

names(precipitation_old)[2] <- "precip_1995_2009"
names(precipitation_new)[2] <- "precip_2010_2024"


regional_comparison <- Reduce(
  function(x, y) merge(x, y, by = "region"),
  list(
    temperature_old,
    temperature_new,
    precipitation_old,
    precipitation_new
  )
)

regional_comparison$temp_change <- (
  regional_comparison$temp_2010_2024 -
    regional_comparison$temp_1995_2009
)

regional_comparison$precip_change <- (
  regional_comparison$precip_2010_2024 -
    regional_comparison$precip_1995_2009
)

regional_comparison <- regional_comparison[
  order(regional_comparison$region),
]

rownames(regional_comparison) <- NULL

cat("\n============================================\n")
cat("REGIONAL PERIOD COMPARISON\n")
cat("============================================\n")
print(regional_comparison)


# ------------------------------------------------------------
# 14. Monthly temperature profile
# ------------------------------------------------------------

monthly_1995_2010 <- parse_monthly_mean_temperature(
  "Lunar 1995-2010"
)

monthly_2011_2024 <- parse_monthly_mean_temperature(
  "Lunar 2011-2024"
)

county_monthly_temperature <- rbind(
  monthly_1995_2010,
  monthly_2011_2024
)


# First aggregate county values to obtain one national value
# for each year and month.

national_monthly <- aggregate(
  mean_temperature ~ year + month,
  data = county_monthly_temperature,
  FUN = mean,
  na.rm = TRUE
)

national_monthly <- national_monthly[
  order(national_monthly$year, national_monthly$month),
]

rownames(national_monthly) <- NULL


# Then calculate the average monthly profile for each 15-year period.

monthly_profile_old <- aggregate(
  mean_temperature ~ month,
  data = subset(
    national_monthly,
    year >= 1995 & year <= 2009
  ),
  FUN = mean,
  na.rm = TRUE
)

monthly_profile_new <- aggregate(
  mean_temperature ~ month,
  data = subset(
    national_monthly,
    year >= 2010 & year <= 2024
  ),
  FUN = mean,
  na.rm = TRUE
)

names(monthly_profile_old)[2] <- "temp_1995_2009"
names(monthly_profile_new)[2] <- "temp_2010_2024"

monthly_profile <- merge(
  monthly_profile_old,
  monthly_profile_new,
  by = "month"
)

monthly_profile <- monthly_profile[
  order(monthly_profile$month),
]

monthly_profile$month_name <- month.name[
  monthly_profile$month
]

monthly_profile$difference <- (
  monthly_profile$temp_2010_2024 -
    monthly_profile$temp_1995_2009
)

monthly_profile <- monthly_profile[
  ,
  c(
    "month",
    "month_name",
    "temp_1995_2009",
    "temp_2010_2024",
    "difference"
  )
]

rownames(monthly_profile) <- NULL

cat("\n============================================\n")
cat("MONTHLY TEMPERATURE PROFILE\n")
cat("============================================\n")
print(monthly_profile)


# ------------------------------------------------------------
# 15. Paired-samples t-test for seasonal profile
# ------------------------------------------------------------

paired_monthly_test <- t.test(
  monthly_profile$temp_2010_2024,
  monthly_profile$temp_1995_2009,
  paired = TRUE
)

average_monthly_shift <- mean(
  monthly_profile$difference
)

cat("\n============================================\n")
cat("PAIRED-SAMPLES T-TEST: MONTHLY PROFILE\n")
cat("============================================\n")

cat(
  "Average shift across the 12 months:",
  round(average_monthly_shift, 3),
  "°C\n\n"
)

print(paired_monthly_test)


# ------------------------------------------------------------
# 16. Export reproducible tables
# ------------------------------------------------------------

utils::write.csv(
  national_annual,
  file.path(
    output_dir,
    "national_annual_temperature.csv"
  ),
  row.names = FALSE
)

utils::write.csv(
  regional_comparison,
  file.path(
    output_dir,
    "regional_climate_comparison.csv"
  ),
  row.names = FALSE
)

utils::write.csv(
  monthly_profile,
  file.path(
    output_dir,
    "monthly_temperature_profile.csv"
  ),
  row.names = FALSE
)


# ------------------------------------------------------------
# 17. Save key statistical results
# ------------------------------------------------------------

newey_west_year_p <- newey_west_results[
  "year",
  ncol(newey_west_results)
]

key_results <- data.frame(
  result = c(
    "OLS annual trend (°C/year)",
    "OLS decadal trend (°C/decade)",
    "OLS R-squared",
    "Mann-Kendall Tau",
    "Mann-Kendall p-value",
    "Mean temperature 1995-2009 (°C)",
    "Mean temperature 2010-2024 (°C)",
    "Difference between periods (°C)",
    "Welch test p-value",
    "Durbin-Watson p-value",
    "Breusch-Pagan p-value",
    "Jarque-Bera p-value",
    "Newey-West p-value for year",
    "Kruskal-Wallis temperature p-value",
    "Kruskal-Wallis precipitation p-value",
    "Average monthly profile shift (°C)",
    "Paired monthly t-test p-value"
  ),
  value = c(
    annual_trend,
    decadal_trend,
    ols_summary$r.squared,
    unname(mann_kendall_test$tau),
    unname(mann_kendall_test$sl),
    mean_1995_2009,
    mean_2010_2024,
    period_difference,
    welch_test$p.value,
    durbin_watson_test$p.value,
    breusch_pagan_test$p.value,
    jarque_bera_test$p.value,
    newey_west_year_p,
    kruskal_temperature$p.value,
    kruskal_precipitation$p.value,
    average_monthly_shift,
    paired_monthly_test$p.value
  ),
  stringsAsFactors = FALSE
)

utils::write.csv(
  key_results,
  file.path(
    output_dir,
    "key_statistical_results.csv"
  ),
  row.names = FALSE
)


# ------------------------------------------------------------
# 18. Save visualisations
# ------------------------------------------------------------

# 18.1 National annual temperature trend

grDevices::png(
  filename = file.path(
    output_dir,
    "national_temperature_trend.png"
  ),
  width = 1400,
  height = 900,
  res = 150
)

plot(
  national_annual$year,
  national_annual$mean_temperature,
  type = "b",
  pch = 16,
  xlab = "Year",
  ylab = "Mean annual temperature (°C)",
  main = "Mean Annual Temperature in Romania (1995-2024)"
)

abline(
  ols_model,
  lwd = 2
)

grid()

grDevices::dev.off()


# 18.2 Regional maximum-temperature comparison

temperature_plot_data <- xtabs(
  max_temperature ~ period + region,
  data = regional_temperature_summary
)

grDevices::png(
  filename = file.path(
    output_dir,
    "regional_max_temperature_comparison.png"
  ),
  width = 1600,
  height = 1000,
  res = 150
)

par(
  mar = c(10, 5, 4, 2) + 0.1
)

barplot(
  temperature_plot_data,
  beside = TRUE,
  las = 2,
  ylab = "Mean maximum temperature (°C)",
  main = "Regional Maximum Temperature: 1995-2009 vs 2010-2024",
  legend.text = rownames(temperature_plot_data),
  args.legend = list(
    x = "topleft",
    bty = "n"
  )
)

grDevices::dev.off()


# 18.3 Regional precipitation comparison

precipitation_plot_data <- xtabs(
  daily_precipitation ~ period + region,
  data = regional_precipitation_summary
)

grDevices::png(
  filename = file.path(
    output_dir,
    "regional_precipitation_comparison.png"
  ),
  width = 1600,
  height = 1000,
  res = 150
)

par(
  mar = c(10, 5, 4, 2) + 0.1
)

barplot(
  precipitation_plot_data,
  beside = TRUE,
  las = 2,
  ylab = "Mean daily precipitation",
  main = "Regional Precipitation: 1995-2009 vs 2010-2024",
  legend.text = rownames(precipitation_plot_data),
  args.legend = list(
    x = "topleft",
    bty = "n"
  )
)

grDevices::dev.off()


# 18.4 Monthly temperature profile

grDevices::png(
  filename = file.path(
    output_dir,
    "monthly_temperature_profile.png"
  ),
  width = 1400,
  height = 900,
  res = 150
)

matplot(
  monthly_profile$month,
  cbind(
    monthly_profile$temp_1995_2009,
    monthly_profile$temp_2010_2024
  ),
  type = "b",
  pch = c(16, 17),
  lty = c(1, 2),
  xaxt = "n",
  xlab = "Month",
  ylab = "Mean temperature (°C)",
  main = "Monthly Temperature Profile: 1995-2009 vs 2010-2024"
)

axis(
  side = 1,
  at = 1:12,
  labels = month.abb
)

legend(
  "topleft",
  legend = c(
    "1995-2009",
    "2010-2024"
  ),
  pch = c(16, 17),
  lty = c(1, 2),
  bty = "n"
)

grid()

grDevices::dev.off()


# ------------------------------------------------------------
# 19. Save a text report of the statistical tests
# ------------------------------------------------------------

results_text_file <- file.path(
  output_dir,
  "statistical_test_output.txt"
)

capture.output(
  {
    cat(
      "STATISTICAL ANALYSIS OF CLIMATE VARIABILITY IN ROMANIA\n"
    )
    cat(
      "Author: Oana - Viviana Scarlat\n"
    )
    cat(
      "Period: 1995-2024\n\n"
    )

    cat(
      "================ OLS MODEL ================\n"
    )
    print(ols_summary)

    cat(
      "\n================ MANN-KENDALL ================\n"
    )
    print(mann_kendall_test)

    cat(
      "\n================ WELCH T-TEST ================\n"
    )
    print(welch_test)

    cat(
      "\n================ JARQUE-BERA ================\n"
    )
    print(jarque_bera_test)

    cat(
      "\n================ DURBIN-WATSON ================\n"
    )
    print(durbin_watson_test)

    cat(
      "\n================ BREUSCH-PAGAN ================\n"
    )
    print(breusch_pagan_test)

    cat(
      "\n================ NEWEY-WEST ================\n"
    )
    print(newey_west_results)

    cat(
      "\n================ KRUSKAL-WALLIS: TEMPERATURE ================\n"
    )
    print(kruskal_temperature)

    cat(
      "\n================ KRUSKAL-WALLIS: PRECIPITATION ================\n"
    )
    print(kruskal_precipitation)

    cat(
      "\n================ PAIRED MONTHLY T-TEST ================\n"
    )
    print(paired_monthly_test)
  },
  file = results_text_file
)


# ------------------------------------------------------------
# 20. Final message
# ------------------------------------------------------------

cat("\n============================================\n")
cat("ANALYSIS COMPLETE\n")
cat("============================================\n")

cat(
  "Outputs saved to:",
  normalizePath(
    output_dir,
    winslash = "/",
    mustWork = FALSE
  ),
  "\n"
)
