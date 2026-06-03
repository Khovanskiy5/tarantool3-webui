# Data Explorer — Collations

## What it is

Tarantool stores every collation (the lexicographic-order rules used
by string index parts) in the `_collation` system space. Built-in
ICU collations cover ~270 locales (`unicode_uk_s2`, `unicode_de_*`,
etc.) plus the implicit default at id 0 and the `binary` and
`unicode` aliases. Operators may add custom rows under their own
user account.

The Data Explorer surfaces this list read-only via the
`collations` GraphQL query so the schema editor can offer a
dropdown when an operator declares a string index part. Without
the list the operator would have to remember collation names by
heart or `box.execute` the `_collation` space directly through the
console.

> Full CRUD on `_collation` (create, drop) lands in **DE-2.5**.
> That surface gates on the `superuser` role because the underlying
> `_collation` space requires `superuser` write privileges.

## API

### Query

```graphql
query Collations {
  collations {
    collations {
      id
      name
      type
      locale
      icu_opts
    }
  }
}
```

### Response shape

```jsonc
{
  "data": {
    "collations": {
      "collations": [
        { "id": 3,   "name": "binary",          "type": "BINARY", "locale": "",   "icu_opts": {} },
        { "id": 239, "name": "unicode_uk_s2",   "type": "ICU",    "locale": "uk", "icu_opts": { "strength": "secondary" } },
        // …
      ]
    }
  }
}
```

* List is sorted by `name` (case-sensitive ASCII) — stable, operator-
  friendly.
* The implicit default at id 0 (`none`) is filtered out: it is the
  fallback every string index already gets, exposing it would
  pretend it is a configurable choice.
* `icu_opts` is the raw map Tarantool stores in field 6 of
  `_collation`. Common keys: `strength`, `alternate`,
  `caseFirst`, `numericCollation`, `frenchCollation`. See ICU
  docs for the full list.
* The `owner` column of `_collation` is intentionally **NOT**
  returned — the schema editor does not surface authorship and
  including it would force a join through `_user`. DE-2.5 brings it
  back when it adds the management surface.

### RBAC

`viewer`+. The query is read-only and contains no auth-sensitive
fields, so any logged-in operator can list collations.

## Operational notes

* The full list is small (300–400 rows) — clients can cache it
  client-side for the session. No pagination is offered.
* Creating a custom collation today requires `box.space._collation`
  write access. Do it from the operator console:
  ```lua
  box.space._collation:auto_increment{
      'my_app_de_strength3',
      box.session.uid(),
      'ICU',
      'de_DE',
      { strength = 'tertiary' },
  }
  ```
  The next `collations` query picks it up immediately — no reload
  required, the resolver re-reads `_collation` on every call.
* To use a collation on a string index part:
  ```lua
  s:create_index('by_name', {
      parts = { { field = 'name', type = 'string',
                  collation = 'unicode_uk_s2' } },
  })
  ```
  Either set it through the future schema editor or directly via
  `space:create_index` until that UI exists.

## Related

* `space.format[i].collation` — collation attached to a format
  field; tuples are normalized on insert using this collation.
* `index.parts[i].collation` — collation used by the index for
  ordering; index parts can override the format-level collation.
* DE-1.4 (Index alter) — will consume this list to populate the
  index-part collation dropdown.
* DE-2.5 (Collation manager) — full CRUD under `superuser`.
