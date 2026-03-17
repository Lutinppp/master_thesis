
#############
#DATA UPLOAD#
#############
library(readr)
library(readxl)
library(data.table)
library(dplyr)
library(lubridate)
library(sandwich)
library(lmtest)
library(ggplot2)
library(patchwork) 
library(scales)

# Fiscal variables
debt_5y_with_gdp    <- read_csv("data/independent_variables/debt_5y_with_gdp.csv")
deficit_5y_with_gdp <- read_csv("data/independent_variables/deficit_5y_with_gdp.csv")

# Interest rate variables
gsw_forward_rates <- read_csv("data/dependent_variables/gsw_forward_rates.csv")
DGS10             <- read_csv("data/dependent_variables/DGS10.csv")
ACMTermPremium    <- read_excel("data/dependent_variables/ACMTermPremium.xls")

# Control variables
EBP       <- read_csv("data/control_variables/EBP.csv")
EXPINF5YR <- read_csv("data/control_variables/EXPINF5YR.csv")
TB3MS     <- read_csv("data/control_variables/TB3MS.csv")
UNPOP     <- read_csv("data/control_variables/UNPOP.csv")
USREC     <- read_csv("data/control_variables/USREC.csv")
FDHBFIN   <- read_csv("data/control_variables/FDHBFIN.csv")
GFDEBTN   <- read_csv("data/control_variables/GFDEBTN.csv")
# FRED nominal GDP (series: GDP), quarterly, bn USD SAAR. Downloaded: 2026-03-17.
# Used to compute 5y-ahead annualised real GDP growth (Furceri et al. 2025, IMF WP/25/142).
GDP_FRED  <- read_csv("data/control_variables/GDP.csv")

#############
# PREP DATES#
#############
setDT(debt_5y_with_gdp);    debt_5y_with_gdp[,    DATE := as.Date(baseline_date, format = "%d/%m/%Y")]
setDT(deficit_5y_with_gdp); deficit_5y_with_gdp[, DATE := as.Date(baseline_date, format = "%d/%m/%Y")]
setDT(gsw_forward_rates);   gsw_forward_rates[,   DATE := as.Date(observation_date)]
setDT(DGS10);               DGS10[,               DATE := as.Date(observation_date)]
setDT(ACMTermPremium);      ACMTermPremium[,      DATE := as.Date(DATE, format = "%d-%b-%Y")]
setDT(EBP);                 EBP[,                 DATE := as.Date(date)]
setDT(EXPINF5YR);           EXPINF5YR[,           DATE := as.Date(observation_date)]
setDT(TB3MS);               TB3MS[,               DATE := as.Date(observation_date)]
setDT(USREC);               USREC[,               DATE := as.Date(observation_date)]
setDT(FDHBFIN);             FDHBFIN[,             DATE := as.Date(observation_date)]
setDT(GFDEBTN);             GFDEBTN[,             DATE := as.Date(observation_date)]
setDT(GDP_FRED);            GDP_FRED[,            DATE := as.Date(observation_date)]

# UNPOP: annual data, extract year and pop growth rate
setDT(UNPOP)
unpop <- UNPOP[, .(year = as.integer(Time), pop_growth = Value)]

##################
# BUILD CONTROLS #
##################

# 1. T-bill
tbill <- TB3MS[, .(DATE, tbill3m = TB3MS)]

# 2. EBP
ebp <- EBP[, .(DATE, ebp)]

# 3. Recession dummy
rec <- USREC[, .(DATE, recession = USREC)]

# 4. Foreign holdings share: foreign holdings / total debt * 100
foreign <- FDHBFIN[GFDEBTN, on="DATE", nomatch=0]
foreign[, foreign_holdings := (FDHBFIN / (GFDEBTN / 1000)) * 100]
foreign <- foreign[, .(DATE, foreign_holdings)]

# 5. Annual actual nominal GDP (FRED): annual mean across all quarters.
#    NOTE: CBO projections prior to ~1992 may be on a GNP rather than GDP basis
#    (BEA switched to GDP as headline measure in Dec 1991). Growth rates for
#    observations with baseline_date before 1992 should be interpreted with caution.
#    The difference between US GNP and GDP is typically below 1%, so the impact
#    on annualised growth rates is minimal.
GDP_FRED[, fyear := as.integer(format(DATE, "%Y"))]
gdp_annual <- GDP_FRED[, .(actual_gdp = mean(GDP, na.rm = TRUE)),
                       by = .(year = fyear)]
setkey(gdp_annual, year)

# 6. Population growth: effective rela
pop_lookup <- function(cbo_years) {
  sapply(cbo_years, function(y) {
    val <- unpop[year == y, pop_growth]
    if(length(val) == 0) NA_real_ else val[1]
  })
}

# 6. GDP growth: 5y ahead nominal CBO growth minus inflation expectations
# nominal growth = GDP column in CBO CSV is already the projected GDP level
# We approximate real growth as: annualized nominal growth - inflation expectation
# nearest inflation expectation matched to CBO release date
inf_lookup <- function(dates) {
  sapply(dates, function(d) {
    idx <- which.min(abs(EXPINF5YR$DATE - d))
    EXPINF5YR$EXPINF5YR[idx]
  })
}

# Rate series for dependent variables
acm <- ACMTermPremium[, .(DATE, tprem5 = ACMTP05, tprem10 = ACMTP10)]
dgs <- DGS10[, .(DATE, t10 = DGS10)]
gsw <- gsw_forward_rates[, .(DATE, fwd_5_10y, fwd_10_15y)]

#################
# MERGE FUNCTION#
#################
join_nearest <- function(base, rate_dt, cols) {
  rate_sub <- rate_dt[, c("DATE", cols), with=FALSE]
  rate_sub <- rate_sub[!is.na(get(cols[1]))]
  rate_sub[base, on="DATE", roll="nearest"]
}

merge_all <- function(cbo_dt) {
  base <- data.table(DATE = cbo_dt$DATE)
  
  out <- join_nearest(base, dgs,     "t10")
  out <- join_nearest(out,  gsw,     c("fwd_5_10y","fwd_10_15y"))
  out <- join_nearest(out,  acm,     c("tprem5","tprem10"))
  out <- join_nearest(out,  tbill,   "tbill3m")
  out <- join_nearest(out,  ebp,     "ebp")
  out <- join_nearest(out,  rec,     "recession")
  out <- join_nearest(out,  foreign, "foreign_holdings")
  
  # Pop growth: 5y ahead based on CBO release year
  out[, pop_growth := pop_lookup(as.integer(format(DATE, "%Y")))]
  
  # GDP growth: annualized nominal GDP growth from CBO minus inflation
  # GDP in CBO CSV = projected GDP level 5y ahead
  # current GDP approximated from FRED or back-calculated
  # Here we use the CBO projected GDP directly as a growth rate proxy
  # by computing: (projected_GDP / lag_projected_GDP)^(1/gap) - 1 - inflation
  # Simpler: store projected GDP and compute after merge
  out[, proj_gdp   := cbo_dt$GDP]
  out[, inflation  := inf_lookup(DATE)]
  
  out
}

################
# BUILD REG DFs#
################
add_trend <- function(dt) {
  dt[, t  := as.numeric(format(DATE, "%Y")) - 1976]
  dt[, t2 := t^2]
  dt
}

# --- DEFICIT dataset ---
df_deficit <- merge_all(deficit_5y_with_gdp)
df_deficit[, fiscal_balance := deficit_5y_with_gdp$deficit_pct_GDP]

# Corrected GDP growth: IMF methodology (Furceri et al. 2025, WP/25/142)
# nominal_growth_t = (CBO_proj_GDP_{t+5} / FRED_actual_GDP_t)^(1/5) * 100 - 100
# real_growth_t    = nominal_growth_t - Michigan 5y inflation expectation
df_deficit[, release_year := as.integer(format(DATE, "%Y"))]
df_deficit[gdp_annual, on = .(release_year = year), actual_gdp := i.actual_gdp]
if (anyNA(df_deficit$actual_gdp))
  warning("df_deficit: ", sum(is.na(df_deficit$actual_gdp)),
          " CBO release year(s) unmatched in FRED GDP; gdp_growth will be NA.")
df_deficit[, gdp_growth := ((proj_gdp / actual_gdp)^(0.2) - 1) * 100 - inflation]
df_deficit[, c("release_year", "actual_gdp") := NULL]
add_trend(df_deficit)

# --- DEBT dataset ---
df_debt <- merge_all(debt_5y_with_gdp)
df_debt[, debt := debt_5y_with_gdp$debt_pct_GDP]
df_debt[, release_year := as.integer(format(DATE, "%Y"))]
df_debt[gdp_annual, on = .(release_year = year), actual_gdp := i.actual_gdp]
if (anyNA(df_debt$actual_gdp))
  warning("df_debt: ", sum(is.na(df_debt$actual_gdp)),
          " CBO release year(s) unmatched in FRED GDP; gdp_growth will be NA.")
df_debt[, gdp_growth := ((proj_gdp / actual_gdp)^(0.2) - 1) * 100 - inflation]
df_debt[, c("release_year", "actual_gdp") := NULL]
add_trend(df_debt)

# --- Sanity check (Step 7) ---
cat("\n--- gdp_growth sanity check (expect ~1-4% p.a.; negatives near 2009 & 2020) ---\n")
cat("df_deficit:\n"); print(summary(df_deficit$gdp_growth))
cat("df_debt:\n");    print(summary(df_debt$gdp_growth))
sanity_dt <- rbind(
  df_deficit[, .(DATE, gdp_growth, dataset = "Deficit")],
  df_debt[,    .(DATE, gdp_growth, dataset = "Debt")]
)
p_sanity <- ggplot(sanity_dt, aes(x = DATE, y = gdp_growth, color = dataset)) +
  geom_line(linewidth = 0.7) +
  geom_hline(yintercept = 0, linetype = "dashed", color = "grey50") +
  scale_color_manual(values = c("Deficit" = "#c0392b", "Debt" = "#1f3a5f")) +
  labs(title = "Sanity check: 5y-ahead expected real GDP growth (Furceri et al. 2025)",
       subtitle = "Should range roughly 1-4% p.a., with negatives around 2009 & 2020",
       x = NULL, y = "% per year", color = NULL) +
  theme_bw(base_size = 10)
ggsave("sanity_gdp_growth.png", p_sanity, width = 8, height = 3.5, dpi = 150, bg = "white")
cat("Sanity plot saved: sanity_gdp_growth.png\n")

#here the goal is to render all models so that we can spot any relationships 
#that might be missed. 
##############
# REGRESSION #
##############

y_vars   <- c("fwd_5_10y","fwd_10_15y","t10","tprem5","tprem10")
y_labels <- c("Fwrd:5-10y","Fwrd:10-15y","T10","TPrem5y","TPrem10y")

run_reg_full <- function(df, y_var, x_var, controls) {
  ctrl <- if(y_var %in% c("tprem5","tprem10")) {
    trimws(gsub("\\+?\\s*tbill3m\\s*\\+?", "+", controls)) |>
      gsub(pattern="^\\+|\\+$", replacement="") |> trimws()
  } else controls
  
  fml <- as.formula(paste(y_var, "~", x_var,
                          if(ctrl != "") paste("+", ctrl) else ""))
  fit <- lm(fml, data=df)
  n   <- nobs(fit)
  lag <- floor(4 * (n/100)^(2/9))
  ct  <- coeftest(fit, vcov=NeweyWest(fit, lag=lag, prewhite=FALSE))
  dw  <- unname(dwtest(fit)$statistic)
  
  c(coef = ct[x_var, "Estimate"],
    se   = ct[x_var, "Std. Error"],
    pval = ct[x_var, "Pr(>|t|)"],
    r2   = summary(fit)$r.squared,
    dw   = dw)
}

print_block_full <- function(res, label) {
  cat(sprintf("%-20s", label),
      paste(sprintf("%12s", sprintf("%.3f%s", res["coef",],
                                    ifelse(res["pval",]<0.01,"***", ifelse(res["pval",]<0.05,"**",
                                                                           ifelse(res["pval",]<0.10,"*",""))))), collapse=""), "\n")
  cat(sprintf("%-20s", ""),
      paste(sprintf("%12s", sprintf("(%.3f)", res["se",])), collapse=""), "\n")
  cat(sprintf("%-20s", "  R²"),
      paste(sprintf("%12s", sprintf("%.3f", res["r2",])), collapse=""), "\n")
  cat(sprintf("%-20s", "  DW"),
      paste(sprintf("%12s", sprintf("%.3f", res["dw",])), collapse=""), "\n")
}
  
specs_sequential <- list(
    # Ordering 1: tbill → trend → controls
    "O1.M1 baseline"           = "",
    "O1.M2 +tbill"             = "tbill3m",
    "O1.M3 +tbill+trend"       = "tbill3m + t",
    "O1.M4 +tbill+trend+ctrl"  = "tbill3m + t + gdp_growth + foreign_holdings + ebp + recession + pop_growth",
    
    # Ordering 2: trend → tbill → controls
    "O2.M2 +trend"             = "t",
    "O2.M3 +trend+tbill"       = "t + tbill3m",
    "O2.M4 +trend+tbill+ctrl"  = "t + tbill3m + gdp_growth + foreign_holdings + ebp + recession + pop_growth",
    
    # Ordering 3: controls → tbill → trend
    "O3.M2 +ctrl"              = "gdp_growth + foreign_holdings + ebp + recession + pop_growth",
    "O3.M3 +ctrl+tbill"        = "gdp_growth + foreign_holdings + ebp + recession + pop_growth + tbill3m",
    "O3.M4 +ctrl+tbill+trend"  = "gdp_growth + foreign_holdings + ebp + recession + pop_growth + tbill3m + t",
    
    # Ordering 4: trend → controls → tbill
    "O4.M2 +trend"             = "t",
    "O4.M3 +trend+ctrl"        = "t + gdp_growth + foreign_holdings + ebp + recession + pop_growth",
    "O4.M4 +trend+ctrl+tbill"  = "t + gdp_growth + foreign_holdings + ebp + recession + pop_growth + tbill3m",
    
    # Ordering 5: tbill → controls → trend
    "O5.M2 +tbill"             = "tbill3m",
    "O5.M3 +tbill+ctrl"        = "tbill3m + gdp_growth + foreign_holdings + ebp + recession + pop_growth",
    "O5.M4 +tbill+ctrl+trend"  = "tbill3m + gdp_growth + foreign_holdings + ebp + recession + pop_growth + t",
    
    # Ordering 6: controls → trend → tbill
    "O6.M2 +ctrl"              = "gdp_growth + foreign_holdings + ebp + recession + pop_growth",
    "O6.M3 +ctrl+trend"        = "gdp_growth + foreign_holdings + ebp + recession + pop_growth + t",
    "O6.M4 +ctrl+trend+tbill"  = "gdp_growth + foreign_holdings + ebp + recession + pop_growth + t + tbill3m"
  )
  
for(spec_name in names(specs_sequential)) {
    controls <- specs_sequential[[spec_name]]
    cat("\n========== MODEL:", spec_name, "==========\n")
    cat(sprintf("%-20s", ""), paste(sprintf("%12s", y_labels), collapse=""), "\n")
    
    debt_res <- sapply(y_vars, function(y) run_reg_full(df_debt,    y, "debt",           controls))
    def_res  <- sapply(y_vars, function(y) run_reg_full(df_deficit, y, "fiscal_balance", controls))
    
    print_block_full(debt_res, "Debt")
    print_block_full(def_res,  "Fiscal Balance")
}

#########################
#Actual model estimation#
#########################

specs_quad <- list(
  "M1: baseline"          = "",
  "M2: +trend"            = "t",
  "M3: +trend+tbill"      = "t + tbill3m",
  "M4: +all controls"     = "t + tbill3m + gdp_growth + foreign_holdings + ebp + recession + pop_growth",
  "M5: +quadratic trend"  = "t + t2 + tbill3m + gdp_growth + foreign_holdings + ebp + recession + pop_growth"
)

for(spec_name in names(specs_quad)) {
  controls <- specs_quad[[spec_name]]
  cat("\n========== MODEL:", spec_name, "==========\n")
  cat(sprintf("%-20s", ""), paste(sprintf("%12s", y_labels), collapse=""), "\n")
  
  debt_res <- sapply(y_vars, function(y) run_reg_full(df_debt,    y, "debt",           controls))
  def_res  <- sapply(y_vars, function(y) run_reg_full(df_deficit, y, "fiscal_balance", controls))
  
  print_block_full(debt_res, "Debt")
  print_block_full(def_res,  "Fiscal Balance")
}

#Visualisations in png for report
#####################
#  FIGURES FOR REPORT
#####################
library(ggplot2)
library(data.table)
library(patchwork) 
library(scales)

# ---- THEME (AER/JFE journal style) ----
theme_paper <- function() {
  theme_bw(base_size = 11, base_family = "serif") +
    theme(
      panel.grid.major   = element_line(color = "grey90", linewidth = 0.3),
      panel.grid.minor   = element_blank(),
      panel.border       = element_rect(color = "black", linewidth = 0.5),
      axis.ticks         = element_line(color = "black", linewidth = 0.3),
      axis.text          = element_text(size = 9, color = "black"),
      axis.title         = element_text(size = 10, color = "black"),
      plot.title         = element_text(size = 11, face = "bold", hjust = 0),
      plot.subtitle      = element_text(size = 9, color = "grey30", hjust = 0),
      legend.position    = "bottom",
      legend.text        = element_text(size = 9),
      legend.key.size    = unit(0.4, "cm"),
      legend.background  = element_blank(),
      strip.background   = element_rect(fill = "grey95", color = "black"),
      strip.text         = element_text(size = 9, face = "bold"),
      plot.margin        = margin(8, 8, 8, 8)
    )
}

#####################
# FIGURE 1
# Time series: Debt, Deficit, and Long-Term Interest Rates
#####################

# Build time series data from your loaded datasets
fig1_debt <- data.table(
  DATE  = debt_5y_with_gdp$DATE,
  value = debt_5y_with_gdp$debt_pct_GDP,
  series = "Projected Debt (% GDP)"
)

fig1_deficit <- data.table(
  DATE  = deficit_5y_with_gdp$DATE,
  value = deficit_5y_with_gdp$deficit_pct_GDP,
  series = "Projected Fiscal Balance (% GDP)"
)

fig1_t10 <- dgs[DATE >= as.Date("1976-01-01"),
                .(DATE, value = t10, series = "10Y Treasury Yield")]

# Panel A: Debt and interest rate
p1a <- ggplot() +
  geom_line(data = fig1_debt,
            aes(x = DATE, y = value, color = "Debt to GDP (lhs)"),
            linewidth = 0.7) +
  geom_line(data = fig1_t10,
            aes(x = DATE, y = value * 10, color = "Long-term nominal rate (rhs)"),
            linewidth = 0.7, linetype = "solid") +
  scale_y_continuous(
    name = "Percent of GDP",
    sec.axis = sec_axis(~ . / 10, name = "Percent")
  ) +
  scale_x_date(date_breaks = "10 years", date_labels = "%Y") +
  scale_color_manual(values = c("Debt to GDP (lhs)" = "#1f3a5f",
                                "Long-term nominal rate (rhs)" = "#c0392b")) +
  labs(title = "(a) Debt and Long-Term Interest Rate",
       x = NULL, color = NULL) +
  theme_paper()

# Panel B: Fiscal balance and interest rate
p1b <- ggplot() +
  geom_hline(yintercept = 0, color = "grey60", linewidth = 0.3) +
  geom_line(data = fig1_deficit,
            aes(x = DATE, y = value, color = "Fiscal Balance (% GDP)"),
            linewidth = 0.7) +
  geom_line(data = fig1_t10,
            aes(x = DATE, y = value - 5, color = "Long-term nominal rate (rhs)"),
            linewidth = 0.7) +
  scale_y_continuous(
    name = "Percent of GDP",
    sec.axis = sec_axis(~ . + 5, name = "Percent")
  ) +
  scale_x_date(date_breaks = "10 years", date_labels = "%Y") +
  scale_color_manual(values = c("Fiscal Balance (% GDP)" = "#1f3a5f",
                                "Long-term nominal rate (rhs)" = "#c0392b")) +
  labs(title = "(b) Fiscal Balance and Long-Term Interest Rate",
       x = NULL, color = NULL) +
  theme_paper()

fig1 <- p1a + p1b +
  plot_annotation(
    title    = "Figure 1: Debt, Fiscal Balances and Long-Term Interest Rates",
    subtitle = "Sources: CBO Historical Budget Data; FRED",
    theme    = theme(
      plot.title    = element_text(size = 12, face = "bold", family = "serif"),
      plot.subtitle = element_text(size = 9,  color = "grey40", family = "serif")
    )
  )

ggsave("figure1_timeseries.png", fig1,
       width = 10, height = 4.5, dpi = 300, bg = "white")

#####################
# FIGURE 2
# Coefficient stability plot (M1 → M4)
# Shows how debt/fiscal coefficients evolve as controls are added
#####################

models <- list(
  "M1: Baseline"      = "",
  "M2: +Trend"        = "t",
  "M3: +Trend+Tbill"  = "t + tbill3m",
  "M4: +All controls" = "t + tbill3m + gdp_growth + foreign_holdings + ebp + recession + pop_growth"
)

# Collect coefficients for fwd_5_10y (main dependent variable)
coef_stability <- rbindlist(lapply(names(models), function(m) {
  ctrl <- models[[m]]
  
  # Debt
  r_debt <- run_reg_full(df_debt, "fwd_5_10y", "debt", ctrl)
  # Fiscal
  r_fisc <- run_reg_full(df_deficit, "fwd_5_10y", "fiscal_balance", ctrl)
  
  rbind(
    data.table(model = m, variable = "Debt",
               coef = r_debt["coef"], se = r_debt["se"]),
    data.table(model = m, variable = "Fiscal Balance",
               coef = r_fisc["coef"], se = r_fisc["se"])
  )
}))

coef_stability[, model := factor(model, levels = names(models))]
coef_stability[, lo := coef - 1.96 * se]
coef_stability[, hi := coef + 1.96 * se]

fig2 <- ggplot(coef_stability,
               aes(x = model, y = coef, color = variable, group = variable)) +
  geom_hline(yintercept = 0, linetype = "dashed", color = "grey50", linewidth = 0.4) +
  geom_ribbon(aes(ymin = lo, ymax = hi, fill = variable),
              alpha = 0.15, color = NA) +
  geom_line(linewidth = 0.8) +
  geom_point(size = 2.5) +
  scale_color_manual(values = c("Debt" = "#1f3a5f", "Fiscal Balance" = "#c0392b")) +
  scale_fill_manual( values = c("Debt" = "#1f3a5f", "Fiscal Balance" = "#c0392b")) +
  facet_wrap(~variable, scales = "free_y") +
  labs(
    title    = "Figure 2: Coefficient Stability Across Specifications",
    subtitle = "Dependent variable: Forward rate 5-10y. Bands = 95% confidence interval (Newey-West SE)",
    x = NULL, y = "Coefficient estimate", color = NULL, fill = NULL
  ) +
  theme_paper() +
  theme(axis.text.x = element_text(angle = 25, hjust = 1),
        legend.position = "none")

ggsave("figure2_coef_stability.png", fig2,
       width = 9, height = 4, dpi = 300, bg = "white")

#####################
# FIGURE 3
# Coefficient across all 5 dependent variables (M4 only)
# AER-style coefficient plot
#####################

dep_labels <- c(
  fwd_5_10y  = "Fwd 5-10y",
  fwd_10_15y = "Fwd 10-15y",
  t10        = "T10",
  tprem5     = "TPrem 5y",
  tprem10    = "TPrem 10y"
)

ctrl_full <- "t + tbill3m + gdp_growth + foreign_holdings + ebp + recession + pop_growth"

coef_cross <- rbindlist(lapply(y_vars, function(y) {
  r_debt <- run_reg_full(df_debt,    y, "debt",           ctrl_full)
  r_fisc <- run_reg_full(df_deficit, y, "fiscal_balance", ctrl_full)
  rbind(
    data.table(depvar = y, variable = "Debt",
               coef = r_debt["coef"], se = r_debt["se"]),
    data.table(depvar = y, variable = "Fiscal Balance",
               coef = r_fisc["coef"], se = r_fisc["se"])
  )
}))

coef_cross[, depvar  := factor(dep_labels[depvar], levels = dep_labels)]
coef_cross[, lo95 := coef - 1.96 * se]
coef_cross[, hi95 := coef + 1.96 * se]
coef_cross[, lo90 := coef - 1.645 * se]
coef_cross[, hi90 := coef + 1.645 * se]

fig3 <- ggplot(coef_cross, aes(x = depvar, y = coef, color = variable)) +
  geom_hline(yintercept = 0, linetype = "dashed", color = "grey50", linewidth = 0.4) +
  geom_linerange(aes(ymin = lo95, ymax = hi95), linewidth = 0.6,
                 position = position_dodge(0.4)) +
  geom_linerange(aes(ymin = lo90, ymax = hi90), linewidth = 1.4,
                 position = position_dodge(0.4)) +
  geom_point(size = 2.5, position = position_dodge(0.4)) +
  scale_color_manual(values = c("Debt" = "#1f3a5f", "Fiscal Balance" = "#c0392b")) +
  facet_wrap(~variable, scales = "free_y") +
  labs(
    title    = "Figure 3: Estimated Coefficients Across Dependent Variables",
    subtitle = "Full controls specification (M4). Thick bars = 90% CI, thin bars = 95% CI (Newey-West SE)",
    x = NULL, y = "Coefficient estimate", color = NULL
  ) +
  theme_paper() +
  theme(legend.position = "none",
        axis.text.x = element_text(angle = 20, hjust = 1))

ggsave("figure3_coef_depvars.png", fig3,
       width = 9, height = 4, dpi = 300, bg = "white")

cat("\nAll figures saved:\n")
cat("  figure1_timeseries.png\n")
cat("  figure2_coef_stability.png\n")
cat("  figure3_coef_depvars.png\n")

#####################
# FIGURE 4
# Newey-West SE Inflation Factor across specs_quad
# Inflation factor = NW SE / OLS SE for the fiscal variable coefficient
#####################

run_reg_inflation <- function(df, y_var, x_var, controls) {
  ctrl <- if(y_var %in% c("tprem5","tprem10")) {
    trimws(gsub("\\+?\\s*tbill3m\\s*\\+?", "+", controls)) |>
      gsub(pattern="^\\+|\\+$", replacement="") |> trimws()
  } else controls

  fml <- as.formula(paste(y_var, "~", x_var,
                          if(ctrl != "") paste("+", ctrl) else ""))
  fit    <- lm(fml, data = df)
  n      <- nobs(fit)
  lag    <- floor(4 * (n / 100)^(2 / 9))
  ct     <- coeftest(fit, vcov = NeweyWest(fit, lag = lag, prewhite = FALSE))

  ols_se <- summary(fit)$coefficients[x_var, "Std. Error"]
  nw_se  <- ct[x_var, "Std. Error"]

  c(ols_se    = ols_se,
    nw_se     = nw_se,
    inflation = nw_se / ols_se)
}

inflation_dt <- rbindlist(lapply(names(specs_quad), function(m) {
  ctrl <- specs_quad[[m]]
  rbindlist(lapply(y_vars, function(y) {
    r_debt <- run_reg_inflation(df_debt,    y, "debt",           ctrl)
    r_fisc <- run_reg_inflation(df_deficit, y, "fiscal_balance", ctrl)
    rbind(
      data.table(spec = m, depvar = y, variable = "Debt",
                 ols_se = r_debt["ols_se"], nw_se = r_debt["nw_se"],
                 inflation = r_debt["inflation"]),
      data.table(spec = m, depvar = y, variable = "Fiscal Balance",
                 ols_se = r_fisc["ols_se"], nw_se = r_fisc["nw_se"],
                 inflation = r_fisc["inflation"])
    )
  }))
}))

inflation_dt[, spec         := factor(spec, levels = names(specs_quad))]
inflation_dt[, depvar_label := factor(dep_labels[depvar], levels = dep_labels)]

# ---- Numerical output for methodology annex ----
cat("\n")
cat("================================================================\n")
cat("  Newey-West SE Inflation Factor  (NW SE / OLS SE)\n")
cat("  Fiscal variable coefficient | specs_quad\n")
cat("================================================================\n")
for (v in c("Debt", "Fiscal Balance")) {
  cat(sprintf("\n--- Inflation factor: %s ---\n", v))
  sub  <- inflation_dt[variable == v, .(spec, depvar_label, inflation)]
  wide <- dcast(sub, spec ~ depvar_label, value.var = "inflation")
  print(wide, digits = 3)
}

cat("\n--- OLS SE (for reference) ---\n")
for (v in c("Debt", "Fiscal Balance")) {
  cat(sprintf("\n  %s:\n", v))
  sub <- inflation_dt[variable == v, .(spec, depvar_label, ols_se)]
  print(dcast(sub, spec ~ depvar_label, value.var = "ols_se"), digits = 4)
}

cat("\n--- Newey-West SE (for reference) ---\n")
for (v in c("Debt", "Fiscal Balance")) {
  cat(sprintf("\n  %s:\n", v))
  sub <- inflation_dt[variable == v, .(spec, depvar_label, nw_se)]
  print(dcast(sub, spec ~ depvar_label, value.var = "nw_se"), digits = 4)
}

# ---- Figure 4 ----
fig4 <- ggplot(inflation_dt,
               aes(x = spec, y = inflation,
                   color = depvar_label, group = depvar_label)) +
  geom_hline(yintercept = 1, linetype = "dashed",
             color = "grey50", linewidth = 0.4) +
  geom_line(linewidth = 0.7) +
  geom_point(size = 2) +
  scale_color_manual(
    values = c("Fwd 5-10y"  = "#1f3a5f",
               "Fwd 10-15y" = "#2980b9",
               "T10"        = "#27ae60",
               "TPrem 5y"   = "#e67e22",
               "TPrem 10y"  = "#c0392b")
  ) +
  facet_wrap(~variable, ncol = 1) +
  labs(
    title    = "Figure 4: Newey-West SE Inflation Factor Across Specifications",
    subtitle = "Inflation factor = NW SE / OLS SE for the fiscal variable coefficient.\nDashed line = 1 (no correction needed).",
    x        = NULL,
    y        = "NW SE / OLS SE",
    color    = "Dependent variable"
  ) +
  theme_paper() +
  theme(axis.text.x   = element_text(angle = 20, hjust = 1),
        legend.position = "right")

ggsave("figure4_nw_inflation.png", fig4,
       width = 9, height = 6, dpi = 300, bg = "white")

cat("  figure4_nw_inflation.png\n")

