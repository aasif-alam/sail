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
 *        "STATUS\t<peers>\t<percent>\t<downloaded>\t<total>\t<speed>" line
 *        once a second (bin/sail renders this as a live display). Stays
 *        alive until SIGTERM/SIGINT.
 * get:   downloads the selected file(s) to <outDir>, emitting the same
 *        STATUS line (aggregated across all selected files) once a second.
 *        Exits 0 once every selected file is complete.
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
  // running download — the caller's watchdog handles real hangs
  process.on('uncaughtException', e => console.error('wt.js ignored:', e.message))

  const clientOpts = { utp: false }
  if (Number.isFinite(opts.torrentPort)) clientOpts.torrentPort = opts.torrentPort
  if (Number.isFinite(opts.dhtPort)) clientOpts.dhtPort = opts.dhtPort
  const client = new WebTorrent(clientOpts)
  // port collisions and tracker hiccups land here; they are not fatal
  client.on('error', e => console.error('webtorrent warning:', e.message || e))

  // only pass announce when non-empty: an empty array would REPLACE the
  // torrent's own trackers with none. deselect:true creates the torrent with
  // NO pieces selected — essential, because for .torrent files _onMetadata
  // (and its select-everything fallback) runs synchronously inside add(),
  // before we could set torrent.so ourselves
  const addOpts = { path: out, deselect: true }
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
  // selected file(s), not the whole torrent, since nothing else is fetched
  // (skipped for meta: it exits long before there is progress to report)
  if (mode !== 'meta') {
    setInterval(() => {
      const wanted = torrent.files.filter((f, i) => sel.includes(i))
      const downloaded = wanted.reduce((a, f) => a + Math.round(f.progress * f.length), 0)
      const total = wanted.reduce((a, f) => a + f.length, 0)
      const percent = total > 0 ? Math.min(100, Math.round(downloaded / total * 100)) : 0
      console.log(`STATUS\t${torrent.numPeers}\t${percent}\t${humanSize(downloaded)}\t${humanSize(total)}\t${humanSize(torrent.downloadSpeed)}/s`)
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
        // bittorrent pieces don't align to file boundaries — a piece
        // shared with a selected file can leave a *fragment* of an
        // unselected neighboring file on disk (right size, mostly zeros,
        // not the real content). Remove anything that wasn't actually
        // asked for so the download folder holds exactly what was picked
        torrent.files.forEach((f, i) => {
          if (sel.includes(i)) return
          const fp = path.join(out, f.path)
          try { fs.rmSync(fp, { force: true }) } catch { /* best-effort */ }
          try { fs.rmdirSync(path.dirname(fp)) } catch { /* not empty, fine */ }
        })
        const bye = () => process.exit(0)
        client.destroy(bye)
        setTimeout(bye, 2000).unref()
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

main()
