/// <reference types="vite/client" />

// JSON imports: Vite transforms them natively. The shell's tsconfig is
// pinned (M0) and does not enable resolveJsonModule, so the wildcard
// declaration below gives the imports a typed `unknown` default export.
// Callers cast through the interfaces in src/i18n / src/layout.
declare module "*.json" {
  const value: unknown;
  export default value;
}
