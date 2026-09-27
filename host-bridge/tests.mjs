import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtemp, readFile, chmod, rm, access } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { test } from 'node:test'
import { protectUrl, publish, unpublish } from './index.js'

const url = 'http://127.0.0.1:19387/?token=test-secret'

test('bridge publishes atomically and unpublishes only matching nonce', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'emacs-dsh-'))
  try {
    await chmod(dir, 0o700)
    const launch = await protectUrl(url, dir)
    const file = await publish(dir, { version: 1, nonce: 'first', launch })
    let value = JSON.parse(await readFile(file, 'utf8'))
    if (process.platform === 'win32') {
      assert.equal(value.launch.encoding, 'dpapi-current-user')
      assert.doesNotMatch(JSON.stringify(value), /test-secret/)
      const script = "Add-Type -AssemblyName System.Security; $b=[Convert]::FromBase64String('" + value.launch.value + "');[Console]::Write([Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect($b,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)))"
      const decrypted = spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', script], { encoding: 'utf8', windowsHide: true })
      assert.equal(decrypted.status, 0, decrypted.stderr)
      assert.equal(decrypted.stdout, url)
    } else {
      assert.deepEqual(value.launch, { encoding: 'plain', value: url })
    }
    await publish(dir, { version: 1, nonce: 'next', launch })
    await unpublish(file, 'first')
    value = JSON.parse(await readFile(file, 'utf8'))
    assert.equal(value.nonce, 'next')
    await unpublish(file, 'next')
    await assert.rejects(access(file), { code: 'ENOENT' })
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

test('public temp directory cannot contain bearer URL on POSIX', async () => {
  if (process.platform === 'win32') return
  const dir = await mkdtemp(path.join(tmpdir(), 'emacs-dsh-'))
  try {
    await chmod(dir, 0o755)
    await assert.rejects(publish(dir, { nonce: 'x' }), /private/)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})
