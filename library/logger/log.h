#pragma once

#include "record.h"
#include "element.h"
#include "backend.h"
#include "priority.h"

#include <util/generic/ptr.h>
#include <functional>
#include <cstdarg>

class TString;

using TLogFormatter = std::function<TString(ELogPriority priority, TStringBuf)>;

class TLog {
public:
    /*
         * construct empty logger
         */
    TLog();

    /*
         * construct file logger
         */
    TLog(const TString& fname, ELogPriority priority = LOG_MAX_PRIORITY);

    /*
         * construct any type of logger :)
         */
    TLog(TAutoPtr<TLogBackend> backend);

    ~TLog();

    /*
         * NOT thread-safe
         */
    void ResetBackend(TAutoPtr<TLogBackend> backend) noexcept;
    TAutoPtr<TLogBackend> ReleaseBackend() noexcept;
    bool IsNullLog() const noexcept;

    void Write(const char* data, size_t len) const;
    void Write(ELogPriority priority, const char* data, size_t len) const;
    void Y_PRINTF_FORMAT(2, 3) AddLog(const char* format, ...) const;
    void Y_PRINTF_FORMAT(3, 4) AddLog(ELogPriority priority, const char* format, ...) const;
    void ReopenLog();
    void ReopenLogNoFlush();

    /*
         * compat methods, remove in near future...
         */
    bool OpenLog(const char* path, ELogPriority lp = LOG_MAX_PRIORITY);
    bool IsOpen() const noexcept;
    void AddLogVAList(const char* format, va_list lst);
    void CloseLog();

    /*
         * This affects all write methods without priority argument
         */
    void SetDefaultPriority(ELogPriority priority) noexcept;
    ELogPriority DefaultPriority() const noexcept;

    ELogPriority FiltrationLevel() const noexcept;

    template <class T>
    inline TLogElement operator<<(const T& t) {
        TLogElement ret(this);
        ret << t;
        return ret;
    }

    void SetFormatter(TLogFormatter formatter) noexcept;

private:
    class TImpl;
    TSimpleIntrusivePtr<TImpl> Impl_;
    TLogFormatter Formatter;
};

TAutoPtr<TLogBackend> CreateLogBackend(const TString& fname, ELogPriority priority = LOG_MAX_PRIORITY, bool threaded = false);
