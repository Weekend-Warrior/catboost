#pragma once

#include <util/generic/string.h>
#include <util/generic/strbuf.h>
#include <util/generic/vector.h>

class IInputStream;
class IOutputStream;

/// @addtogroup Streams_HTTP
/// @{
/// Объект, содержащий информацию о HTTP-заголовке.
class THttpInputHeader {
public:
    /// @param[in] header - строка вида 'параметр: значение'.
    THttpInputHeader(const TString& header);
    /// @param[in] name - имя параметра.
    /// @param[in] value - значение параметра.
    THttpInputHeader(const TString& name, const TString& value);

    ~THttpInputHeader();

    /// Возвращает имя параметра.
    inline const TString& Name() const noexcept {
        return Name_;
    }

    /// Возвращает значение параметра.
    inline const TString& Value() const noexcept {
        return Value_;
    }

    /// Записывает заголовок вида "имя параметра: значение\r\n" в поток.
    void OutTo(IOutputStream* stream) const;

    /// Возвращает строку "имя параметра: значение".
    inline TString ToString() const {
        return Name_ + AsStringBuf(": ") + Value_;
    }

private:
    TString Name_;
    TString Value_;
};

/// Контейнер для хранения HTTP-заголовков
class THttpHeaders {
    typedef TVector<THttpInputHeader> THeaders;

public:
    typedef THeaders::const_iterator TConstIterator;

    THttpHeaders();
    /// Добавляет каждую строку из потока в контейнер, считая ее правильным заголовком.
    THttpHeaders(IInputStream* stream);
    ~THttpHeaders();

    /// Стандартный итератор.
    inline TConstIterator Begin() const noexcept {
        return Headers_.begin();
    }
    inline TConstIterator begin() const noexcept {
        return Headers_.begin();
    }

    /// Стандартный итератор.
    inline TConstIterator End() const noexcept {
        return Headers_.end();
    }
    inline TConstIterator end() const noexcept {
        return Headers_.end();
    }

    /// Возвращает количество заголовков в контейнере.
    inline size_t Count() const noexcept {
        return Headers_.size();
    }

    /// Проверяет, содержит ли контейнер хотя бы один заголовок.
    inline bool Empty() const noexcept {
        return Headers_.empty();
    }

    /// Добавляет заголовок в контейнер.
    void AddHeader(const THttpInputHeader& header);

    template <typename ValueType>
    void AddHeader(const TString& name, const ValueType& value) {
        AddHeader(THttpInputHeader(name, ToString(value)));
    }

    /// Добавляет заголовок в контейнер, если тот не содержит заголовка
    /// c таким же параметром. В противном случае, заменяет существующий
    /// заголовок на новый.
    void AddOrReplaceHeader(const THttpInputHeader& header);

    // Проверяет, есть ли такой заголовок
    bool HasHeader(const TString& header) const;

    /// Удаляет заголовок, если он есть.
    void RemoveHeader(const TString& header);

    /// Записывает все заголовки контейнера в поток.
    /// @details Каждый заголовк записывается в виде "имя параметра: значение\r\n".
    void OutTo(IOutputStream* stream) const;

    /// Обменивает наборы заголовков двух контейнеров.
    void Swap(THttpHeaders& headers) noexcept {
        Headers_.swap(headers.Headers_);
    }

private:
    THeaders Headers_;
};

/// @}
