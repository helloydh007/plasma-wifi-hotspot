#!/usr/bin/env node
// UI 状态机回归测试（Node 直接跑 plasmoid/contents/ui/state.js 的纯函数）。
//
// 为什么要有这一层：phase/offBadge 以前内联在 main.qml 里，qmllint 只能查语法，
// 语义 bug 漏到了实机。2026-09-17 的 bug：
//   开机重启后后端服务 active/running（监督脚本在待命），热点没发信标，
//   但 offBadge 把 standby 当成了"没关"，托盘不画红色斜线。
//
// 用法：node tests/test-ui-state.js
'use strict'

const fs = require('fs')
const path = require('path')
const vm = require('vm')

const repo = path.resolve(__dirname, '..')
const src = fs.readFileSync(path.join(repo, 'plasmoid/contents/ui/state.js'), 'utf8')
    // .pragma library 是 QML 的指令，不是 JS
    .replace(/^\s*\.pragma\s+library\s*$/m, '')

const ctx = { console }
vm.createContext(ctx)
vm.runInContext(src, ctx, { filename: 'state.js' })
const { phaseOf, offBadgeOf } = ctx

let pass = 0
let fail = 0
function check(name, actual, expected) {
    if (actual === expected) {
        pass++
        console.log(`  ok   ${name}`)
    } else {
        fail++
        console.log(`  FAIL ${name}：期望 [${expected}] 实际 [${actual}]`)
    }
}

function st(overrides) {
    return Object.assign({
        mode: 'concurrent',
        disabled: false,
        hotspot: { running: 'no' },
        concurrent_service_state: 'inactive/dead',
        normal_service_state: 'inactive/dead'
    }, overrides)
}

console.log('== A) 开机自启后的待命：热点没发信标 → 必须画关闭斜线（本次 bug 的回归）==')
{
    const s = st({ concurrent_service_state: 'active/running' })
    const phase = phaseOf(s, false)
    check('服务 active/running 且无信标 → phase=standby', phase, 'standby')
    check('standby 必须画红色斜线', offBadgeOf(phase), true)
}

console.log('== B) 真的在发信标 / 正在启动：不能画斜线 ==')
{
    check('hotspot.running=yes → running', phaseOf(st({ hotspot: { running: 'yes' } }), false), 'running')
    check('running 不画斜线', offBadgeOf('running'), false)
    check('用户点开启、等信标 → starting', phaseOf(st({ concurrent_service_state: 'active/running' }), true), 'starting')
    check('starting 不画斜线', offBadgeOf('starting'), false)
    check('systemd activating/auto-restart → starting', phaseOf(st({ concurrent_service_state: 'activating/auto-restart' }), false), 'starting')
    check('activating 不画斜线', offBadgeOf('starting'), false)
}

console.log('== C) 关闭 / 后端失败 / 后端不可用：都要画斜线 ==')
{
    check('disabled=true → off', phaseOf(st({ disabled: true, concurrent_service_state: 'active/running' }), false), 'off')
    check('off 画斜线', offBadgeOf('off'), true)
    check('服务 inactive → off', phaseOf(st({ concurrent_service_state: 'inactive/dead' }), false), 'off')
    check('failed/failed → failed', phaseOf(st({ concurrent_service_state: 'failed/failed' }), false), 'failed')
    check('failed 画斜线', offBadgeOf('failed'), true)
    check('status 没 mode → unavailable', phaseOf({}, false), 'unavailable')
    check('unavailable 画斜线', offBadgeOf('unavailable'), true)
}

console.log('== D) normal 模式必须看 normal_service_state，别被 concurrent 带偏 ==')
{
    const s = st({
        mode: 'normal',
        concurrent_service_state: 'active/running',   // 并发残留在跑，但当前模式是 normal
        normal_service_state: 'inactive/dead'
    })
    check('normal 模式按 normal_service_state 判 off', phaseOf(s, false), 'off')
    check('normal 模式真的在跑 → running', phaseOf(st({ mode: 'normal', normal_service_state: 'active/running', hotspot: { running: 'yes' } }), false), 'running')
}

console.log('== E) 缺失/异常字段不能抛异常 ==')
{
    let ok = true
    try {
        phaseOf(undefined, false)
        phaseOf(null, true)
        phaseOf({ mode: 'concurrent' }, false)
        phaseOf({ mode: 'concurrent', hotspot: null }, false)
        phaseOf({ mode: 'concurrent', concurrent_service_state: null }, false)
    } catch (e) {
        ok = false
        console.log(`       异常：${e && e.message}`)
    }
    check('缺字段/ null 不抛异常', ok, true)
}

console.log(`\nUI 状态机测试：${pass} 通过，${fail} 失败`)
process.exit(fail === 0 ? 0 : 1)
