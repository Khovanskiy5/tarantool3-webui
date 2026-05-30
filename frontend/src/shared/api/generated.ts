/* eslint-disable */
//
// Public barrel for the GraphQL types and operations emitted by
// graphql-codegen. The actual artefacts live under
// `./__generated/` (codegen owns that folder and rewrites it on
// every `bunx graphql-codegen` run); this file is hand-written
// and re-exports both schema types and operation documents so
// consumers can keep importing from `@/shared/api/generated`.
//
export * from './__generated/graphql';
export * from './__generated/gql';
