# -*- coding: utf-8 -*-
"""Runtime payload for _launcher.boot().

Environment is baked into the Docker image; this payload only runs the
license watchdog and the hidden service bootstrap. It is embedded into
_launcher.so at build time (XOR -> app_payload.h) and never ships as
plaintext.  ASCII-only: stored inside the C extension.  Identifiers are
kept deliberately terse so in-process traces reveal nothing meaningful.
"""
import os
import subprocess
import threading
import time


def _probe():
    try:
        from lazyllm.launcher.base import _is_npu_available, parse_npu_smi_info
        if _is_npu_available():
            out = subprocess.check_output(['npu-smi', 'info'],
                                          encoding='utf-8', errors='ignore')
            vis = (os.getenv('ASCEND_RT_VISIBLE_DEVICES') or '').strip()
            def _phys():
                try:
                    return sorted({int(n[7:]) for n in os.listdir('/dev')
                                   if n.startswith('davinci') and n[7:].isdigit()})
                except OSError:
                    return []
            phys = _phys()
            # 容器直挂卡: npu-smi 只列挂载的卡, /dev/davinci 存在时不再拿 env 过滤
            allowed = None if phys else (vis.split(',') if vis else None)
            if allowed is not None:
                allowed = set(int(x) for x in allowed)
            print('ASCEND_RT_VISIBLE_DEVICES = %s%s' %
                  (vis or '(auto pick idlest)',
                   '  (physical: %s)' % ','.join(map(str, phys)) if phys else ''),
                  flush=True)
            for dev in parse_npu_smi_info(out):
                mark = '*' if (allowed is None or dev['index'] in allowed) else ' '
                print('  %s NPU %s: free %s / %s MiB' % (mark, dev['index'],
                      dev['hbm_free_mib'], dev['hbm_total_mib']), flush=True)
        else:
            print('WARN: NPU unavailable in container', flush=True)
    except Exception as exc:
        print('NPU preflight skipped:', repr(exc), flush=True)


def _w():
    check_interval = 30
    try:
        import _launcher
        check_interval = int(getattr(_launcher, 'CHECK_INTERVAL_SECONDS', 30))
    except Exception:
        pass
    while True:
        time.sleep(check_interval)
        try:
            import _launcher
            _launcher.check()
        except Exception:
            pass


def _svc():
    # burned-in bootstrap; source exists only inside _launcher.so
    import lazyllm
    from lazyllm.tools.infer_service.serve import InferServer
    from lazyllm.tools.train_service.serve import TrainServer

    infer = lazyllm.ServerModule(
        InferServer(), port='31340',
        launcher=lazyllm.launcher.EmptyLauncher(sync=False, ngpus=2))
    train = lazyllm.ServerModule(
        TrainServer(), port='31341',
        launcher=lazyllm.launcher.EmptyLauncher(sync=False, ngpus=2))
    infer.start()()
    train.start()()
    print('llm-service ready: AMS=0.0.0.0:31340  FT=0.0.0.0:31341', flush=True)
    infer.wait()
    train.wait()


def _go():
    import _launcher
    print('[license] expiry=%s interval=%ds tolerance=%ds' % (
        time.strftime('%Y-%m-%d %H:%M:%S',
                      time.localtime(int(_launcher.EXPIRY_TIMESTAMP))),
        _launcher.CHECK_INTERVAL_SECONDS, _launcher.CHECK_TOLERANCE_SECONDS),
        flush=True)
    _probe()
    threading.Thread(target=_w, daemon=True).start()
    _svc()


if __name__ == '__main__':
    _go()