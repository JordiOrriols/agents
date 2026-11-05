# Working rules

## Commit in small pieces, as you go

Every commit is one milestone you could describe in a sentence, and it leaves
the repo in a state worth having. Commit right after a change works.

Never commit a failing test. If a new test exposes a bug, commit the fix first
and the test right after, so each commit is green on its own.

## Checks

```sh
npm run compile && npm run lint && npm run format:check
npm run test:coverage   # web app, 80% coverage minimum
npm run test:runner     # Python runner, standard library only
```

## Shared code

The header, layout, workspaces, sign-in, dialogs and styling come from
`@jordiorriols/ui`. Reuse them instead of copying markup; anything another app
could use belongs in the `ui` repository.

All visible text lives in `src/locales/*.json` (en, es, ca, fr, de, it). The
locale and inline-copy tests fail when a key is missing or text is hard-coded.

## Database

The Supabase project is shared with Ladders, Planner, Pulse and Shiplog.
`supabase/migrations` holds the whole shared history so `supabase db push` sees
every remote version. Add new migrations after the latest one, test them in
`src/data/__tests__/agentsDatabase.test.ts`, and apply them only with the
user's approval.

## Secrets

Never write credentials, tokens or `runner/config.toml` into a commit, a file
in the repo or a summary.
