/*
 * LazyLLM 许可守护 —— Python C 扩展 (_launcher)
 * =========================================================
 * 编译期烧入参数 (由 build_license.py 生成的 license_config.h 提供):
 *   LICENSE_EXPIRY_TIMESTAMP         过期时间戳 (unix 秒)
 *   LICENSE_MAX_INTERVAL_SECONDS     授权总时长 (打包时刻 -> 过期)
 *   LICENSE_CHECK_INTERVAL_SECONDS   后台巡检间隔 (秒)
 *   LICENSE_CHECK_TOLERANCE_SECONDS  允许的时钟浮动误差 (秒)
 *
 * 运行时业务逻辑 (app_main.py, XOR 混淆后经 build_license.py 生成 app_payload.h)
 * 被解密并在此进程内执行, 源码不进镜像:
 *   LICENSE_EXPIRY_TIMESTAMP 之外, 另含 APP_PAYLOAD / APP_PAYLOAD_KEY。
 *
 * 对外接口:
 *   _launcher.boot()   启动校验 + 解密执行内嵌业务逻辑 (主入口)
 *   _launcher.run([cb])   启动校验(过期/间隔合法); 通过后可回调 cb
 *   _launcher.check()   持续校验(时间连续性); 失败直接 _exit(1)
 *   _launcher.expiry()  返回烧入的过期时间戳
 *   _launcher.params()  返回烧入的四个参数
 *
 * 任意校验失败均调用 _exit(1), 绕过 Python 异常与 atexit, Python 层无法 try/except。
 *
 * 无 license_config.h 时使用下面的默认值 (EXPIRY=0 => 启动校验直接拒绝, fail-closed);
 * 无 app_payload.h 时 boot() 拒绝启动 (fail-closed)。
 */
#define PY_SSIZE_T_CLEAN
#include <Python.h>
#include <time.h>
#include <unistd.h>

#if defined(__has_include)
#  if __has_include("license_config.h")
#    include "license_config.h"
#  endif
#  if __has_include("app_payload.h")
#    include "app_payload.h"
#  endif
#endif

#ifndef LICENSE_EXPIRY_TIMESTAMP
#define LICENSE_EXPIRY_TIMESTAMP 0LL
#endif
#ifndef LICENSE_MAX_INTERVAL_SECONDS
#define LICENSE_MAX_INTERVAL_SECONDS 0LL
#endif
#ifndef LICENSE_CHECK_INTERVAL_SECONDS
#define LICENSE_CHECK_INTERVAL_SECONDS 30LL
#endif
#ifndef LICENSE_CHECK_TOLERANCE_SECONDS
#define LICENSE_CHECK_TOLERANCE_SECONDS 5LL
#endif

/* 上一次巡检的时间戳; 0 表示尚未初始化 */
static long long g_last_check = 0;

static long long now_seconds(void) {
    time_t t = time(NULL);
    if (t == (time_t)-1) _exit(1);   /* 取时间失败 -> fail-closed */
    return (long long)t;
}

/*
 * 启动时校验 (run/boot 共用):
 *   1) 未授权            EXPIRY <= 0       -> 拒绝
 *   2) 已过期            now > EXPIRY      -> 拒绝
 *   3) 间隔非法          interval <= 0     -> 拒绝
 *   4) 间隔过大(时钟回拨) interval > MAX    -> 拒绝
 */
static int run_guard_internal(void) {
    long long now, interval, max_interval;

    now = now_seconds();
    interval = (long long)LICENSE_EXPIRY_TIMESTAMP - now;
    max_interval = (long long)LICENSE_MAX_INTERVAL_SECONDS;

    if ((long long)LICENSE_EXPIRY_TIMESTAMP <= 0LL) return -1;
    if (now > (long long)LICENSE_EXPIRY_TIMESTAMP) return -1;
    if (interval <= 0) return -1;
    if (interval > max_interval) return -1;

    g_last_check = now;
    return 0;
}

/*
 * 解密并执行内嵌业务逻辑 (app_main.py)。
 * APP_PAYLOAD 为 XOR 混淆后的字节, APP_PAYLOAD_KEY 为回滚密钥。
 */
static int payload_exec(void) {
    size_t i, n;
    char *buf;
    int rc;

#ifdef APP_PAYLOAD_H
    n = sizeof(APP_PAYLOAD);
#else
    (void)i; (void)n;
    return -1;   /* 未嵌入 -> fail-closed */
#endif

    buf = (char *)PyMem_Malloc(n + 1);
    if (buf == NULL) return -1;
    for (i = 0; i < n; i++)
        buf[i] = (char)(APP_PAYLOAD[i]
                        ^ APP_PAYLOAD_KEY[i % sizeof(APP_PAYLOAD_KEY)]);
    buf[n] = '\0';

    rc = PyRun_SimpleString(buf);
    PyMem_Free(buf);
    return rc;
}

/*
 * 启动校验 + 可选回调 (兼容旧用法)。
 */
static PyObject *guard_run(PyObject *self, PyObject *args) {
    PyObject *callback = NULL;

    (void)self;
    if (!PyArg_ParseTuple(args, "|O", &callback)) return NULL;
    if (run_guard_internal() != 0) _exit(1);

    if (callback != NULL && callback != Py_None) {
        PyObject *res = PyObject_CallNoArgs(callback);
        if (res == NULL) return NULL;
        Py_DECREF(res);
    }
    Py_RETURN_NONE;
}

/*
 * 主入口: 启动校验通过后, 解密执行内嵌业务; 失败立即 _exit(1)。
 */
static PyObject *guard_boot(PyObject *self, PyObject *args) {
    (void)self;
    (void)args;

    if (run_guard_internal() != 0) _exit(1);
    if (payload_exec() != 0) _exit(1);
    Py_RETURN_NONE;
}

/*
 * 持续校验:
 *   a) 已过期        now >  EXPIRY            -> _exit (运行中到期立即终止)
 *   b) 时间连续性 (delta = now - last)
 *      回拨   delta < 0            -> _exit
 *      加速   delta < min_allowed  -> _exit
 *      减速   delta > max_allowed  -> _exit (含进程被冻结/断网改时间)
 */
static PyObject *guard_check(PyObject *self, PyObject *args) {
    long long now, delta, min_allowed, max_allowed;

    (void)self;
    (void)args;

    now = now_seconds();
    if (now > (long long)LICENSE_EXPIRY_TIMESTAMP) _exit(1);  /* 运行期过期 */

    if (g_last_check == 0) {
        g_last_check = now;
        Py_RETURN_NONE;
    }

    delta = now - g_last_check;
    min_allowed = (long long)LICENSE_CHECK_INTERVAL_SECONDS - (long long)LICENSE_CHECK_TOLERANCE_SECONDS;
    max_allowed = (long long)LICENSE_CHECK_INTERVAL_SECONDS + (long long)LICENSE_CHECK_TOLERANCE_SECONDS;

    if (delta < 0) _exit(1);
    if (delta < min_allowed) _exit(1);
    if (delta > max_allowed) _exit(1);

    g_last_check = now;
    Py_RETURN_NONE;
}

static PyObject *guard_expiry(PyObject *self, PyObject *args) {
    (void)self;
    (void)args;
    return PyLong_FromLongLong((long long)LICENSE_EXPIRY_TIMESTAMP);
}

static PyObject *guard_params(PyObject *self, PyObject *args) {
    (void)self;
    (void)args;
    return Py_BuildValue("{sLsLsLsL}",
                         "expiry", (long long)LICENSE_EXPIRY_TIMESTAMP,
                         "max_interval", (long long)LICENSE_MAX_INTERVAL_SECONDS,
                         "check_interval", (long long)LICENSE_CHECK_INTERVAL_SECONDS,
                         "tolerance", (long long)LICENSE_CHECK_TOLERANCE_SECONDS);
}

static PyMethodDef guard_methods[] = {
    {"boot", guard_boot, METH_NOARGS, "主入口: 启动校验 + 执行内嵌业务"},
    {"run", guard_run, METH_VARARGS, "启动时许可校验; 可选回调, 校验通过后调用"},
    {"check", guard_check, METH_NOARGS, "持续许可校验, 失败 _exit(1)"},
    {"expiry", guard_expiry, METH_NOARGS, "返回烧入的过期时间戳"},
    {"params", guard_params, METH_NOARGS, "返回烧入的许可参数"},
    {NULL, NULL, 0, NULL}
};

static struct PyModuleDef guard_module = {
    PyModuleDef_HEAD_INIT,
    "_launcher",
    "LazyLLM license guard",
    -1,
    guard_methods,
    NULL, NULL, NULL, NULL
};

PyMODINIT_FUNC PyInit__launcher(void) {
    PyObject *m = PyModule_Create(&guard_module);
    if (m == NULL) return NULL;
    PyModule_AddIntConstant(m, "EXPIRY_TIMESTAMP", (long)LICENSE_EXPIRY_TIMESTAMP);
    PyModule_AddIntConstant(m, "MAX_INTERVAL_SECONDS", (long)LICENSE_MAX_INTERVAL_SECONDS);
    PyModule_AddIntConstant(m, "CHECK_INTERVAL_SECONDS", (long)LICENSE_CHECK_INTERVAL_SECONDS);
    PyModule_AddIntConstant(m, "CHECK_TOLERANCE_SECONDS", (long)LICENSE_CHECK_TOLERANCE_SECONDS);
    return m;
}