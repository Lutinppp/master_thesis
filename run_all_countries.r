#############################################
#  BATCH RUNNER: All Countries at Once
#############################################
# Run this script to execute the analysis for all countries sequentially
# It will source analysis_country.r with the appropriate COUNTRY setting for each

COUNTRIES <- c("germany", "france", "uk")

for (country in COUNTRIES) {
  cat("\n\n")
  cat("████████████████████████████████████████████████████████████\n")
  cat(paste0("  PROCESSING: ", toupper(country), "\n"))
  cat("████████████████████████████████████████████████████████████\n\n")
  
  # Create temporary script with country set
  temp_script <- tempfile(fileext = ".r")
  
  script_content <- sprintf(
    'COUNTRY <- "%s"\n\n%s',
    country,
    paste(readLines("analysis_country.r"), collapse = "\n")
  )
  
  writeLines(script_content, temp_script)
  
  tryCatch(
    source(temp_script),
    error = function(e) {
      cat(sprintf("\n❌ Error processing %s:\n", toupper(country)))
      cat(sprintf("  %s\n", e$message))
    }
  )
  
  unlink(temp_script)
}

cat("\n\n")
cat("████████████████████████████████████████████████████████████\n")
cat("  ALL COUNTRIES PROCESSED\n")
cat("████████████████████████████████████████████████████████████\n")
cat("Check output/ directory for individual country results\n")
