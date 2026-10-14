// DMD Name rules — identical to DMDRegistrarController.valid() and DmdNameResolver.isValidName():
// 2-63 chars of a-z 0-9 '-', starts & ends alphanumeric, no "--". Names are labels without ".dmd".
const ALNUM = /^[a-z0-9]$/

export function normalizeName(input: string): string {
  let s = input.trim().toLowerCase()
  if (s.endsWith('.dmd')) s = s.slice(0, -4)
  return s
}

export function isValidDmdName(name: string): boolean {
  if (name.length < 2 || name.length > 63) return false
  if (!ALNUM.test(name[0]) || !ALNUM.test(name[name.length - 1])) return false
  for (let i = 1; i < name.length; i++) {
    const c = name[i]
    if (c !== '-' && !ALNUM.test(c)) return false
    if (c === '-' && name[i - 1] === '-') return false
  }
  return true
}

/** Why a name is invalid, in plain words (for inline hints). */
export function nameProblem(name: string): string | null {
  if (name.length === 0) return null
  if (name.length < 2) return 'Names have at least 2 characters.'
  if (name.length > 63) return 'Names have at most 63 characters.'
  if (/[^a-z0-9-]/.test(name)) return 'Names use only letters a–z, digits and hyphens.'
  if (name.startsWith('-') || name.endsWith('-')) return 'Names can’t start or end with a hyphen.'
  if (name.includes('--')) return 'Names can’t contain two hyphens in a row.'
  return null
}
