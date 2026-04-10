You have been asked a question about {{OWNER}}/{{REPO}} by @lefticus.

## ⚑ QUESTION FROM @lefticus

> Source: {{DIRECTIVE_SOURCE}}

```
{{LEFTICUS_DIRECTIVE}}
```

## Context: {{CONTEXT_TYPE}} #{{N}}

### Title
{{TITLE}}

### Body
{{CONTEXT_BODY}}

### Conversation thread
{{COMMENTS}}

## Your workspace
- Repo is checked out at: {{WORKDIR}}
- You can read any file in the repo to understand the codebase.
- Your shell starts in this workdir.

## Build & test commands (for reference)
{{BUILD_BLOCK}}

## Your task

1. **Read @lefticus's question carefully.** Understand what they're asking about.
2. **Explore the codebase** as needed to give a well-informed answer. Read relevant source files, check how things are structured, look at tests, etc.
3. **Think through the question.** Consider trade-offs, potential issues, and alternatives.
4. **Write a clear, helpful reply.**

## Output format

Output your reply between these exact markers. The wrapper will extract the text between them and post it as a GitHub comment.

---BEGIN COMMENT---
(your reply here — use markdown formatting, be concise but thorough)
---END COMMENT---

Keep your reply focused and useful. You're commenting on a public GitHub thread, so:
- Be professional and helpful
- Reference specific files/lines when relevant (use relative paths)
- If you see potential issues with a proposed approach, explain them clearly
- If you're unsure about something, say so rather than guessing
- Don't be excessively verbose — aim for the length that matches the complexity of the question
