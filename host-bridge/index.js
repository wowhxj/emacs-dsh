// Explicitly enabled local bridge; no unauthenticated HTTP endpoint.
import { randomBytes, randomUUID } from 'node:crypto'
import { spawnSync } from 'node:child_process'
import { promises as fs } from 'node:fs'
import { homedir } from 'node:os'
import path from 'node:path'

export const name = 'emacs-dsh-host-bridge'
export const inject = ['connection', 'webServer']

const FILENAME = 'emacs-dsh-bridge.json'
function privateDirectory() { return process.env.DSH_HOME || path.join(homedir(), '.dsh') }

async function assertPrivateDirectory(directory) {
  const info = await fs.lstat(directory)
  if (!info.isDirectory() || info.isSymbolicLink()) throw new Error('emacs-dsh: DSH_HOME must be a real directory')
  if (process.platform !== 'win32' && (info.mode & 0o077) !== 0) {
    throw new Error('emacs-dsh: DSH_HOME must be private (chmod 700) before enabling bridge')
  }
}

/** DPAPI via PowerShell stdin. The bearer URL never appears in a command line
 * or a temporary file; only the encrypted result is published. */
export async function protectUrl(url, directory = privateDirectory()) {
  if (process.platform !== 'win32') return { encoding: 'plain', value: url }
  await assertPrivateDirectory(directory)
  const script = "$ErrorActionPreference='Stop'; Add-Type -AssemblyName System.Security; "
    + "$b=[Text.Encoding]::UTF8.GetBytes([Console]::In.ReadToEnd()); "
    + "$p=[Security.Cryptography.ProtectedData]::Protect($b,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser); "
    + "[Console]::Write([Convert]::ToBase64String($p))"
  const run = spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', script], {
    input: url, encoding: 'utf8', windowsHide: true, timeout: 10000,
    maxBuffer: 8192,
  })
  if (run.status !== 0) {
    throw new Error(`emacs-dsh: DPAPI protection failed (exit ${run.status}, ${run.error?.message || 'PowerShell error'})`)
  }
  const cipher = run.stdout.trim()
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(cipher)) throw new Error('emacs-dsh: invalid DPAPI ciphertext')
  return { encoding: 'dpapi-current-user', value: cipher }
}

/** Atomic publication, never expose a half-written credential record. */
export async function publish(directory, value) {
  await assertPrivateDirectory(directory)
  const target = path.join(directory, FILENAME)
  const temporary = path.join(directory, `.${FILENAME}.${randomBytes(12).toString('hex')}`)
  try {
    await fs.writeFile(temporary, JSON.stringify(value) + '\n', { flag: 'wx', mode: 0o600 })
    await fs.rename(temporary, target)
  } finally {
    await fs.rm(temporary, { force: true })
  }
  return target
}

export async function unpublish(file, nonce) {
  try {
    const info = await fs.lstat(file)
    if (!info.isFile() || info.isSymbolicLink()) return
    const current = JSON.parse(await fs.readFile(file, 'utf8'))
    if (current.nonce === nonce) await fs.unlink(file)
  } catch (error) {
    if (error.code !== 'ENOENT') throw error
  }
}

export function apply(ctx) {
  const nonce = randomUUID()
  const directory = privateDirectory()
  const base = `http://127.0.0.1:${ctx.webServer.port}/`
  let live = true
  let published
  const ready = (async () => {
    const launch = await protectUrl(ctx.connection.authenticatedUrl(base), directory)
    const file = await publish(directory, { version: 1, pid: process.pid, nonce, url: base, launch })
    if (live) published = file
    else await unpublish(file, nonce)
  })().catch((error) => { console.error(`emacs-dsh: bridge unavailable: ${String(error)}`) })
  ctx.effect(() => async () => {
    live = false
    await ready
    if (published) await unpublish(published, nonce)
  }, 'emacs-dsh-host-bridge')
}
