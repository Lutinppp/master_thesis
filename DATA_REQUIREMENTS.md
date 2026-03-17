# Master Thesis - Europa: Multi-Country Analysis Setup

## Project Structure

```
/workspaces/master_thesis_evropa/
├── data/
│   ├── us/
│   │   ├── independent_variables/     (debt_5y_with_gdp.csv, deficit_5y_with_gdp.csv)
│   │   ├── dependent_variables/       (gsw_forward_rates.csv, long_rate.csv, ACMTermPremium.xls)
│   │   └── control_variables/         (EBP.csv, EXPINF5YR.csv, TBILL.csv, etc.)
│   ├── germany/
│   │   ├── independent_variables/
│   │   ├── dependent_variables/
│   │   └── control_variables/
│   ├── france/
│   │   ├── independent_variables/
│   │   ├── dependent_variables/
│   │   └── control_variables/
│   └── uk/
│       ├── independent_variables/
│       ├── dependent_variables/
│       └── control_variables/
├── output/                             (auto-generated per country)
│   ├── us/
│   ├── germany/
│   ├── france/
│   └── uk/
├── previouswork.r                     (Original US analysis)
└── analysis_country.r                 (NEW: Template for all countries)
```

## Data Files Required for Each Country

### Independent Variables (`independent_variables/`)
- **debt_5y_with_gdp.csv**: Columns needed: `baseline_date`, `value` (debt as % of GDP)
- **deficit_5y_with_gdp.csv**: Columns needed: `baseline_date`, `value` (deficit as % of GDP)

### Dependent Variables (`dependent_variables/`)
- **long_rate.csv**: Columns needed: `observation_date`, `value` (long-term interest rate)
- **gsw_forward_rates.csv** (optional): Columns needed: `observation_date`, `fwd_5_10y`, `fwd_10_15y`
- **ACMTermPremium.xls** (optional): Term premium data (country-specific format)

### Control Variables (`control_variables/`)
- **EXPINF5YR.csv**: Expected inflation 5 years ahead. Columns: `observation_date`, `value`
- **TBILL.csv**: Short-term interest rate. Columns: `observation_date`, `value`
- **UNPOP.csv**: Population growth (annual). Columns: `time_period`, `year`, `Value`
- **REC.csv**: Recession indicator (0/1). Columns: `observation_date`, `value`
- **GDP_ACTUAL.csv**: Actual GDP (for growth calculations). Columns: `observation_date`, `gdp`
- **EBP.csv** (optional): Excess bond premium. Columns: `observation_date`, `value`
- **FOREIGN.csv** (optional): Foreign holdings share. Columns: `observation_date`, `value`

## How to Use

### Step 1: Add Your Data Files
For each country (germany, france, uk), add the CSV files to the appropriate subdirectories under `data/{country}/`.

### Step 2: Run the Analysis
Edit `analysis_country.r` and change the `COUNTRY` variable at line 7:

```r
# For Germany
COUNTRY <- "germany"

# For France
COUNTRY <- "france"

# For UK
COUNTRY <- "uk"
```

Then run the script in R:
```r
source("analysis_country.r")
```

### Step 3: Output
Results will be saved to `output/{country}/` including:
- `sanity_gdp_growth.png` - Sanity check visualization
- Console output with regression tables

## Notes

### Column Name Flexibility
The script uses standard column names:
- `observation_date` or `baseline_date` for dates
- `value` for most numeric variables
- If your data uses different names, modify the `read_csv()` calls in the script

### Date Formats
Default date format is assumed to be "YYYY-MM-DD". If your country's data uses a different format (e.g., "DD/MM/YYYY"), modify the date parsing section:

```r
# Line ~70 of analysis_country.r
debt_5y_with_gdp[, DATE := as.Date(baseline_date, format = "%d/%m/%Y")]  # adjust format string
```

### Missing Variables
If some optional variables (EBP, FOREIGN, ACMTermPremium, etc.) are not available for a country, the script will:
- Skip them gracefully
- Set them to NA
- Continue the analysis with available data

### Sourcing Previous Results
Your original `previouswork.r` analysis is preserved and can still be referenced or sourced for comparison.

## Key Differences from US (previouswork.r)

1. **Modular Design**: One script for all countries (no copy-paste needed)
2. **Flexible Column Names**: Adapts to `rate_long` or `t10`, `st_rate` or `tbill3m`, etc.
3. **Optional Variables**: Handles missing variables gracefully
4. **Structured Output**: Results organized in country-specific output folders
5. **Control Variable Naming**: Uses standardized names (`st_rate`, `risk_ind`, etc.) instead of country-specific codes (TB3MS, EBP, etc.)

## To Do
- [ ] Obtain & add debt/deficit data for Germany, France, UK
- [ ] Obtain & add interest rate data for each country
- [ ] Obtain & add control variables for each country
- [ ] Run `analysis_country.r` for each country
- [ ] Review sanity checks and regression output
- [ ] Generate publication figures (similar to `previouswork.r`)
