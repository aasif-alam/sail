#!/usr/bin/env node
/* Torrent runner for sail: drives the webtorrent module directly so sail can
 * select exactly the file(s) it wants in a multi-file torrent — streaming
 * one file over HTTP, or downloading a chosen set straight to disk.
 *
 * webtorrent-cli is not usable for either: its --select/-i selection does
 * not actually restrict what gets fetched when downloading (confirmed: even
 * with --select N, every file in the torrent still lands on disk), and its
 * interactive picker only ever supports choosing one file. Driving the
 * library directly makes selection actually work.
 *
 *   wt.js <module-dir> meta  <torrentId> <outDir>
 *   wt.js <module-dir> serve <torrentId> <outDir> <idx>          <optsJson> [port]
 *   wt.js <module-dir> get   <torrentId> <outDir> <idx[,idx...]> <optsJson>
 *
 * optsJson: {"announce": [...], "torrentPort": N, "dhtPort": N, "serverPort": N}
 *
 * meta:  fetches the metadata (instantly for a .torrent file, from the
 *        swarm for a magnet), writes <outDir>/<infohash>.torrent, info.json
 *        and files.tsv (one row per file: id, human size, path — the same
 *        shape the old webtorrent-info + python converter produced),
 *        prints "INFOHASH=<hash>", and exits 0. One process where sail
 *        used to pay for three boots (webtorrent downloadmeta,
 *        webtorrent info, python).
 *
 * serve: prints "PORT=<n>" once the HTTP server is listening, then a
 *        "STATUS\t<peers>\t<percent>\t<downloaded>\t<total>\t<speed>\t<upSpeed>\t<uploaded>\t<eta>\t<ratio>\t<knownPeers>"
 *        line plus a "PEERS\t<addr>|<client>|<down>|<up>|<have>;..." line
 *        once a second (bin/sail renders these as a live dashboard). Stays
 *        alive until SIGTERM/SIGINT.
 * get:   downloads the selected file(s) to <outDir>, emitting the same
 *        PEERS + STATUS pair (aggregated across all selected files) once a
 *        second. Bytes land in a hidden per-run staging directory and only
 *        the selected files are moved into <outDir> once complete, so a
 *        killed run can never leave fragments of unselected files behind.
 *        Exits 0 once every selected file is complete.
 *
 * Both get and serve abort when no bytes arrive for SAIL_STALL_TIMEOUT
 * seconds (default 300, 0 disables) — a dead swarm used to hang forever.
 */
'use strict'

const path = require('path')
const fs = require('fs')

const humanSize = n => {
  n = Number(n) || 0
  for (const unit of ['B', 'KB', 'MB', 'GB', 'TB']) {
    if (n < 1024) return `${n.toFixed(1)}${unit}`
    n /= 1024
  }
  return `${n.toFixed(1)}PB`
}

const usage = () => {
  console.error('usage: wt.js <module-dir> meta|serve|get <torrentId> <outDir> [idx[,idx...]] [optsJson] [port]')
  process.exit(3)
}

// Downloads are staged in a hidden directory inside the destination, then
// only the selected files are moved out. Two reasons:
//   - bittorrent pieces don't align to file boundaries, so fetching one
//     episode of a season pack writes fragments of its neighbours too.
//     Staging + deleting the whole stage means those never reach the
//     user's folder, and a pre-existing file is never touched.
//   - an interrupted run leaves only the hidden stage behind, which the
//     next run cleans up (the pid in its name is gone by then).
const STAGING_PREFIX = '.sail-partial-'

const stagingDirFor = outDir =>
  path.join(outDir, `${STAGING_PREFIX}${process.pid}-${Date.now().toString(36)}`)

const pidAlive = pid => {
  try {
    process.kill(pid, 0)
    return true
  } catch (e) {
    return e.code === 'EPERM'
  }
}

// remove stages left by runs that no longer exist. A live pid is never
// touched, so two sails downloading into the same folder can't collide.
const cleanupStaleStaging = outDir => {
  let entries = []
  try { entries = fs.readdirSync(outDir, { withFileTypes: true }) } catch { return }
  for (const entry of entries) {
    if (!entry.isDirectory() || !entry.name.startsWith(STAGING_PREFIX)) continue
    const m = /^\.sail-partial-(\d+)-/.exec(entry.name)
    const pid = m ? Number(m[1]) : NaN
    if (Number.isFinite(pid) && pidAlive(pid)) continue
    try { fs.rmSync(path.join(outDir, entry.name), { recursive: true, force: true }) } catch { /* best-effort */ }
  }
}

// move the selected files out of the stage, preserving their paths
const moveSelected = (torrentFiles, sel, from, to) => {
  const moved = []
  torrentFiles.forEach((f, i) => {
    if (!sel.includes(i)) return
    const src = path.join(from, f.path)
    const dst = path.join(to, f.path)
    fs.mkdirSync(path.dirname(dst), { recursive: true })
    try {
      fs.renameSync(src, dst)
    } catch (e) {
      // different filesystem (should not happen: the stage is inside `to`)
      fs.copyFileSync(src, dst)
      fs.rmSync(src, { force: true })
    }
    moved.push(f.path)
  })
  return moved
}

const main = async () => {
  const [, , modDir, mode, id, out, selArg, optsArg, portArg] = process.argv
  if (!modDir || !mode || !id || !out) usage()
  if (mode !== 'serve' && mode !== 'get' && mode !== 'meta') usage()

  let opts = {}
  try { opts = JSON.parse(optsArg || '{}') } catch { /* keep empty */ }
  // meta takes no selection — it fetches metadata only, nothing downloads
  const sel = mode === 'meta'
    ? []
    : String(selArg || '').split(',').map(Number).filter(Number.isFinite)
  if (mode !== 'meta' && sel.length === 0) usage()

  let WebTorrent
  try {
    ;({ default: WebTorrent } = await import('file://' + path.resolve(modDir, 'index.js')))
  } catch (e) {
    console.error('cannot load webtorrent module:', e.message)
    process.exit(3)
  }

  // upstream bugs (utp-native crash on port collision) must not kill a
  // running download. Anything else is a real fault: log it and exit, so
  // sail reports a failure instead of hanging against a dead process.
  process.on('uncaughtException', e => {
    const msg = String((e && e.message) || e)
    if (/utp|EADDRINUSE|EACCES/i.test(msg)) {
      console.error('wt.js ignored:', msg)
      return
    }
    console.error('wt.js fatal:', msg)
    process.exit(1)
  })

  const clientOpts = { utp: false }
  if (Number.isFinite(opts.torrentPort)) clientOpts.torrentPort = opts.torrentPort
  if (Number.isFinite(opts.dhtPort)) clientOpts.dhtPort = opts.dhtPort
  const client = new WebTorrent(clientOpts)
  // port collisions and tracker hiccups land here; they are not fatal
  client.on('error', e => console.error('webtorrent warning:', e.message || e))

  // downloads land in a hidden stage first (see stagingDirFor); the other
  // modes write where the caller asked
  let staging = null
  if (mode === 'get') {
    cleanupStaleStaging(out)
    staging = stagingDirFor(out)
    fs.mkdirSync(staging, { recursive: true })
  }

  // only pass announce when non-empty: an empty array would REPLACE the
  // torrent's own trackers with none. deselect:true creates the torrent with
  // NO pieces selected — essential, because for .torrent files _onMetadata
  // (and its select-everything fallback) runs synchronously inside add(),
  // before we could set torrent.so ourselves
  const addOpts = { path: staging || out, deselect: true }
  if (Array.isArray(opts.announce) && opts.announce.length) addOpts.announce = opts.announce
  const torrent = client.add(id, addOpts)
  torrent.on('error', e => {
    console.error('torrent error:', e.message || e)
    process.exit(1)
  })

  // select only the wanted file(s) once the file list exists — 'ready'
  // fires after the library finished its own selection setup
  torrent.on('ready', () => {
    torrent.files.forEach((f, i) => { if (sel.includes(i)) f.select() })
  })

  // live status for bin/sail's terminal display — progress across just the
  // selected file(s), not the whole torrent, since nothing else is fetched.
  // One PEERS line (per-wire detail, fastest downloaders first) followed by
  // one STATUS line per tick, so a renderer reading the log bottom-up sees
  // a consistent pair (skipped for meta: it exits long before there is
  // progress to report)
  if (mode !== 'meta') {
    // client name for the peers table — bittorrent-peerid ships beside the
    // webtorrent module in webtorrent-cli installs. require() the directory
    // (require(esm) works on node >= 22); require.resolve can't see it —
    // the package's "exports" map has no require condition. When the module
    // is missing or unrequireable, fall back to the raw azureus-style
    // two-letter prefix
    let peerid = null
    try {
      peerid = require(path.join(modDir, '..', 'bittorrent-peerid')).default || null
    } catch { /* prefix fallback below */ }
    const clientName = wire => {
      // wire.peerId is the hex form; bittorrent-peerid wants the 20 raw bytes
      const raw = wire.peerIdBuffer || null
      if (peerid && raw) {
        try { return (peerid(raw).client || '?').replace(/\s*\(.*\)$/, '') } catch { /* malformed peer id */ }
      }
      const id = raw ? raw.toString('utf8') : ''
      return id.startsWith('-') && id.length >= 3 ? id.slice(1, 3) : '?'
    }
    // how much of the whole torrent the peer has, from its have-bitfield
    const peerHave = wire => {
      const bf = wire.peerPieces
      const n = torrent.pieces ? torrent.pieces.length : 0
      if (!bf || !bf.buffer || !bf.buffer.length || !n) return 0
      let have = 0
      try { for (let i = 0; i < n; i++) if (bf.get(i)) have++ } catch { return 0 }
      return Math.round(have / n * 100)
    }
    const eta = () => {
      const ms = torrent.timeRemaining
      if (!Number.isFinite(ms)) return '∞'
      const s = Math.round(ms / 1000)
      if (s < 60) return `${s}s`
      if (s < 3600) return `${Math.floor(s / 60)}m ${String(s % 60).padStart(2, '0')}s`
      return `${Math.floor(s / 3600)}h ${String(Math.floor((s % 3600) / 60)).padStart(2, '0')}m`
    }
    // a dead swarm used to leave this process (and sail's dashboard)
    // running forever: abort when no bytes have arrived for a while.
    // SAIL_STALL_TIMEOUT is in seconds; 0 turns the watchdog off.
    const stallRaw = process.env.SAIL_STALL_TIMEOUT
    const stallNum = Number(stallRaw)
    const stallSeconds = stallRaw === undefined || stallRaw === ''
      ? 300
      : (Number.isFinite(stallNum) ? stallNum : 300)
    let lastDownloaded = -1
    let lastProgressAt = Date.now()
    let stalling = false

    setInterval(() => {
      const wanted = torrent.files.filter((f, i) => sel.includes(i))
      const downloaded = wanted.reduce((a, f) => a + Math.round(f.progress * f.length), 0)
      const total = wanted.reduce((a, f) => a + f.length, 0)
      const percent = total > 0 ? Math.min(100, Math.round(downloaded / total * 100)) : 0

      if (!stalling && Number.isFinite(stallSeconds) && stallSeconds > 0) {
        if (wanted.length > 0 && wanted.some(f => !f.done)) {
          if (downloaded > lastDownloaded) {
            lastDownloaded = downloaded
            lastProgressAt = Date.now()
          } else if (Date.now() - lastProgressAt > stallSeconds * 1000) {
            stalling = true
            console.error(`stalled: no data received for ${stallSeconds}s — giving up`)
            const bye = () => process.exit(1)
            client.destroy(bye)
            setTimeout(bye, 2000)
            return
          }
        } else {
          lastDownloaded = downloaded
          lastProgressAt = Date.now()
        }
      }
      const peers = torrent.wires
        .map(w => ({
          addr: w.remoteAddress || '?',
          client: clientName(w),
          down: w.downloadSpeed(),
          up: w.uploadSpeed(),
          have: peerHave(w)
        }))
        .sort((a, b) => b.down - a.down)
        .slice(0, 8)
      console.log('PEERS\t' + peers.map(p =>
        `${p.addr}|${p.client}|${humanSize(p.down)}/s|${humanSize(p.up)}/s|${p.have}%`).join(';'))
      console.log(`STATUS\t${torrent.numPeers}\t${percent}\t${humanSize(downloaded)}\t${humanSize(total)}\t${humanSize(torrent.downloadSpeed)}/s\t${humanSize(torrent.uploadSpeed)}/s\t${humanSize(torrent.uploaded)}\t${eta()}\t${torrent.ratio.toFixed(2)}\t${torrent._peersLength || 0}`)
    }, 1000).unref()
  }

  if (mode === 'meta') {
    // 'ready' implies torrentFile, files and infoHash are all populated
    // (webtorrent-cli's downloadmeta writes the same torrentFile buffer)
    torrent.on('ready', () => {
      try {
        const hash = torrent.infoHash
        fs.writeFileSync(path.join(out, `${hash}.torrent`), torrent.torrentFile)
        const files = torrent.files.map(f => ({ path: f.path, length: f.length }))
        fs.writeFileSync(path.join(out, 'info.json'), JSON.stringify({
          name: torrent.name,
          infoHash: hash,
          length: torrent.length,
          files
        }, null, 2))
        console.log(`INFOHASH=${hash}`)
        // files.tsv is sail's success signal, so it lands last and via
        // rename — a kill mid-run can never leave a truncated list behind
        const tsv = path.join(out, 'files.tsv')
        fs.writeFileSync(tsv + '.tmp', files.map((f, i) =>
          `${i}\t${humanSize(f.length)}\t${f.path}`).join('\n') + '\n')
        fs.renameSync(tsv + '.tmp', tsv)
        // exit directly, no client.destroy(): meta fetched nothing, and the
        // writes above are synchronous, so there is nothing to flush —
        // destroy() instead parks ~2s waiting for in-flight tracker
        // announces to drain, which would tax every sail run
        process.exit(0)
      } catch (e) {
        console.error('meta: write failed:', e.message)
        process.exit(1)
      }
    })
    return
  }

  if (mode === 'get') {
    // 'done' is unreliable with deselected files — watch the wanted files
    // themselves and exit once every one of them is complete
    const check = () => {
      const wanted = torrent.files.filter((f, i) => sel.includes(i))
      if (wanted.length > 0 && wanted.every(f => f.done)) {
        clearInterval(poll)
        // move only what was picked; the rest of the stage (fragments of
        // neighbouring files, unselected episodes) is deleted wholesale
        let code = 0
        try {
          moveSelected(torrent.files, sel, staging, out)
          fs.rmSync(staging, { recursive: true, force: true })
        } catch (e) {
          console.error('get: could not move completed files:', e.message)
          code = 1
        }
        const bye = () => process.exit(code)
        client.destroy(bye)
        setTimeout(bye, 2000)
      }
    }
    const poll = setInterval(check, 250)
    check()
    return
  }

  // serve: http server for the player, stays alive until killed
  let server
  try {
    server = client.createServer({}, 'node').server
  } catch (e) {
    console.error('cannot create stream server:', e.message)
    process.exit(1)
  }
  const listen = port => {
    const s = server.listen(port)
    s.once('listening', () => console.log(`PORT=${s.address().port}`))
    s.once('error', err => {
      if (err.code === 'EADDRINUSE' || err.code === 'EACCES') {
        s.close()
        listen(0) // fall back to any free port
      } else {
        console.error('listen error:', err.message)
        process.exit(1)
      }
    })
  }
  listen(Number(portArg) || Number(opts.serverPort) || 0)

  const shutdown = () => client.destroy(() => process.exit(0))
  process.on('SIGTERM', shutdown)
  process.on('SIGINT', shutdown)
}

if (require.main === module) main()
module.exports = { stagingDirFor, cleanupStaleStaging, moveSelected, STAGING_PREFIX }
