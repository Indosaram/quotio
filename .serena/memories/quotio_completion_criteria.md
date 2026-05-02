# Task completion criteria for Quotio

When finishing a change:
- Verify modified Swift files with diagnostics
- Run the relevant Xcode build command if the task changes code paths that affect compilation
- Confirm UI/runtime behavior manually if the change affects screens or provider display logic
- Summarize exactly what changed and any follow-up caveats

For research-only tasks, return reusable patterns with file paths and no code edits.
