/*
 * Copyright (c) 2024 OTArchive <https://otarchive.com>
 * Copyright (c) 2010-2022 OTClient <https://github.com/edubart/otclient>
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */
#ifdef __EMSCRIPTEN__

#include "webconnection.h"

#include <framework/core/application.h>

#include <utility>
#include <framework/core/eventdispatcher.h>

std::list<std::shared_ptr<asio::streambuf>> WebConnection::m_outputStreams;
WebConnection::WebConnection()
{
}

WebConnection::~WebConnection()
{
#ifndef NDEBUG
    assert(!g_app.isTerminated());
#endif
    close();
}

void WebConnection::poll()
{
}

void WebConnection::terminate()
{
    emscripten_websocket_deinitialize();
    m_outputStreams.clear();
}

void WebConnection::close()
{
    cleanup(true);
}

void WebConnection::cleanup(const bool sendCloseFrame)
{
    const auto socket = std::exchange(m_websocket, 0);

    m_connecting = false;
    m_connected = false;
    m_connectCallback = nullptr;
    m_errorCallback = nullptr;
    m_recvCallback = nullptr;
    m_pendingReadSize = 0;
    m_deferredError.clear();
    m_remoteErrorPending = false;
    m_sendCloseFrameOnError = true;

    if (m_readTimeoutEvent) {
        m_readTimeoutEvent->cancel();
        m_readTimeoutEvent = nullptr;
    }

    m_readCompletionPending = false;
    ++m_readCompletionGeneration;

    const auto inputSize = m_inputStream.size();
    m_inputStream.consume(inputSize);
    releaseBufferedBytes(inputSize);
    if (m_outputStream) {
        onWrite(m_outputStream);
        m_outputStream = nullptr;
    }

    if (socket < 1)
        return;

    emscripten_websocket_set_onopen_callback(socket, nullptr, nullptr);
    emscripten_websocket_set_onerror_callback(socket, nullptr, nullptr);
    emscripten_websocket_set_onclose_callback(socket, nullptr, nullptr);
    emscripten_websocket_set_onmessage_callback(socket, nullptr, nullptr);
    if (sendCloseFrame)
        emscripten_websocket_close(socket, 1000, "client close");
    emscripten_websocket_delete(socket);
}

void WebConnection::connect(const std::string_view host, uint16_t /*port*/, const std::function<void()>& connectCallback, bool /*gameWorld*/)
{
    if (m_connected || m_connecting || m_websocket > 0) {
        notifyError(asio::error::already_connected);
        return;
    }

    m_connected = false;
    m_connecting = true;
    m_connectCallback = connectCallback;

    const std::string url(host);
    if (!url.starts_with("ws://") && !url.starts_with("wss://")) {
        g_logger.error("Browser connections require an explicit ws:// or wss:// endpoint");
        notifyError(asio::error::invalid_argument);
        return;
    }

    EmscriptenWebSocketCreateAttributes attributes =
    {
        url.c_str(),
        "binary",
        EM_FALSE // if the webscocket should be created in the main thread. Currently not implemented by emscripten so this does nothing
    };

    m_websocket = emscripten_websocket_new(&attributes);

    if (m_websocket < 1) {
        notifyError(asio::error::network_unreachable);
        return;
    }

    emscripten_websocket_set_onopen_callback(m_websocket, this, ([](int /*eventType*/, const EmscriptenWebSocketOpenEvent* event, void* userData) -> EM_BOOL {
        if (!event)
            return EM_TRUE;
        const auto connection = static_cast<WebConnection*>(userData)->asWebConnection();
        const auto socket = event->socket;
        g_dispatcher.addEvent([connection, socket] { connection->handleOpen(socket); });
        return EM_TRUE;
    }));

    emscripten_websocket_set_onerror_callback(m_websocket, this, ([](int /*eventType*/, const EmscriptenWebSocketErrorEvent* event, void* userData) -> EM_BOOL {
        if (!event)
            return EM_TRUE;
        const auto connection = static_cast<WebConnection*>(userData)->asWebConnection();
        const auto socket = event->socket;
        g_dispatcher.addEvent([connection, socket] {
            connection->handleRemoteError(socket, asio::error::connection_reset, true);
        });
        return EM_TRUE;
    }));

    emscripten_websocket_set_onclose_callback(m_websocket, this, ([](int /*eventType*/, const EmscriptenWebSocketCloseEvent* event, void* userData) -> EM_BOOL {
        if (!event)
            return EM_TRUE;
        const auto connection = static_cast<WebConnection*>(userData)->asWebConnection();
        const auto socket = event->socket;
        g_dispatcher.addEvent([connection, socket] {
            connection->handleRemoteError(socket, asio::error::connection_reset, false);
        });
        return EM_TRUE;
    }));

    emscripten_websocket_set_onmessage_callback(m_websocket, this, ([](int /*eventType*/, const EmscriptenWebSocketMessageEvent* webSocketEvent, void* userData) -> EM_BOOL {
        if (!webSocketEvent)
            return EM_TRUE;

        auto connection = static_cast<WebConnection*>(userData)->asWebConnection();
        const auto socket = webSocketEvent->socket;
        const size_t payloadSize = webSocketEvent->numBytes;
        if (!connection->reserveBufferedBytes(payloadSize)) {
            g_dispatcher.addEvent([connection, socket] {
                if (connection->m_websocket == socket)
                    connection->notifyError(asio::error::no_buffer_space);
            });
            return EM_TRUE;
        }

        std::vector<uint8_t> payload;
        if (webSocketEvent->data && payloadSize > 0) {
            payload.assign(webSocketEvent->data, webSocketEvent->data + payloadSize);
        }
        const bool isText = webSocketEvent->isText;
        g_dispatcher.addEvent([connection, socket, payload = std::move(payload), payloadSize, isText]() mutable {
            connection->handleMessage(socket, std::move(payload), payloadSize, isText);
        });
        return EM_TRUE;
    }));
}

void WebConnection::handleOpen(const EMSCRIPTEN_WEBSOCKET_T socket)
{
    if (!m_connecting || m_websocket != socket)
        return;

    m_connected = true;
    m_connecting = false;
    m_activityTimer.restart();

    const auto callback = std::move(m_connectCallback);
    if (callback)
        callback();
}

void WebConnection::handleMessage(const EMSCRIPTEN_WEBSOCKET_T socket, std::vector<uint8_t> payload, const size_t reservedSize, const bool isText)
{
    if (!m_connected || m_websocket != socket) {
        releaseBufferedBytes(reservedSize);
        return;
    }

    if (isText) {
        releaseBufferedBytes(reservedSize);
        notifyError(asio::error::operation_not_supported);
        return;
    }

    if (payload.size() != reservedSize) {
        releaseBufferedBytes(reservedSize);
        notifyError(asio::error::connection_reset);
        return;
    }

    if (payload.empty()) {
        releaseBufferedBytes(reservedSize);
        return;
    }

    std::ostream stream(&m_inputStream);
    stream.write(reinterpret_cast<const char*>(payload.data()), payload.size());
    stream.flush();
    scheduleReadCompletion();
}

void WebConnection::handleRemoteError(const EMSCRIPTEN_WEBSOCKET_T socket, const std::error_code& error, const bool sendCloseFrame)
{
    if (m_websocket != socket)
        return;

    m_remoteErrorPending = true;
    m_deferredError = error;
    m_sendCloseFrameOnError = m_sendCloseFrameOnError && sendCloseFrame;
    finishDeferredError();
}

void WebConnection::finishDeferredError()
{
    if (!m_remoteErrorPending || m_readCompletionPending)
        return;

    if (m_recvCallback && m_inputStream.size() >= m_pendingReadSize) {
        scheduleReadCompletion();
        return;
    }

    notifyError(m_deferredError, m_sendCloseFrameOnError);
}

bool WebConnection::reserveBufferedBytes(const size_t size)
{
    if (size > MAX_BUFFERED_BYTES)
        return false;

    size_t buffered = m_bufferedBytes.load(std::memory_order_relaxed);
    do {
        if (buffered > MAX_BUFFERED_BYTES - size)
            return false;
    } while (!m_bufferedBytes.compare_exchange_weak(buffered, buffered + size, std::memory_order_acq_rel));
    return true;
}

void WebConnection::releaseBufferedBytes(const size_t size)
{
    if (size > 0)
        m_bufferedBytes.fetch_sub(size, std::memory_order_acq_rel);
}

void WebConnection::notifyError(const std::error_code& error, const bool sendCloseFrame)
{
    if (!m_connected && !m_connecting && m_websocket < 1)
        return;

    const auto self = asWebConnection();
    const auto callback = std::move(m_errorCallback);
    cleanup(sendCloseFrame);
    if (callback)
        callback(error);
    (void)self;
}

bool WebConnection::sendPacket(uint8_t* buffer, uint16_t size)
{
    if (m_websocket < 1)
        return false;

    unsigned short readyState = 0;
    if (emscripten_websocket_get_ready_state(m_websocket, &readyState) != EMSCRIPTEN_RESULT_SUCCESS || readyState != 1)
        return false;

    const EMSCRIPTEN_RESULT result = emscripten_websocket_send_binary(m_websocket, buffer, size);
    return (result == EMSCRIPTEN_RESULT_SUCCESS);
}

void WebConnection::write(uint8_t* buffer, size_t size)
{
    if (!m_connected)
        return;

    if (!m_outputStream) {
        if (!m_outputStreams.empty()) {
            m_outputStream = m_outputStreams.front();
            m_outputStreams.pop_front();
        } else
            m_outputStream = std::make_shared<asio::streambuf>();
    }

    std::ostream os(m_outputStream.get());
    os.write((const char*)buffer, size);
    os.flush();

    internal_write();
}

void WebConnection::internal_write()
{
    if (!m_connected)
        return;

    std::shared_ptr<asio::streambuf> outputStream = m_outputStream;
    m_outputStream = nullptr;

    const auto* data = asio::buffer_cast<const uint8_t*>(outputStream->data());
    const bool written = sendPacket((uint8_t*)data, outputStream->size());
    onWrite(outputStream);
    if (!written) {
        notifyError(asio::error::connection_reset);
    }
}

void WebConnection::read(const uint16_t size, const RecvCallback& callback)
{
    if (!m_connected)
        return;

    if (m_recvCallback) {
        notifyError(asio::error::operation_not_supported);
        return;
    }

    m_pendingReadSize = size;
    m_recvCallback = callback;
    scheduleReadCompletion();

    if (m_readCompletionPending)
        return;

    const std::weak_ptr<WebConnection> weakConnection = asWebConnection();
    m_readTimeoutEvent = g_dispatcher.scheduleEvent([weakConnection] {
        if (const auto connection = weakConnection.lock(); connection && connection->m_recvCallback) {
            connection->m_readTimeoutEvent = nullptr;
            connection->notifyError(asio::error::timed_out);
        }
    }, READ_TIMEOUT * 1000);
}

void WebConnection::onWrite(const std::shared_ptr<asio::streambuf>& outputStream)
{
    // free output stream and store for using it again later
    outputStream->consume(outputStream->size());
    m_outputStreams.emplace_back(outputStream);
}

void WebConnection::scheduleReadCompletion()
{
    if (m_readCompletionPending || !m_recvCallback || m_inputStream.size() < m_pendingReadSize)
        return;

    if (m_readTimeoutEvent) {
        m_readTimeoutEvent->cancel();
        m_readTimeoutEvent = nullptr;
    }

    const std::weak_ptr<WebConnection> weakConnection = asWebConnection();
    m_readCompletionPending = true;
    const uint64_t generation = ++m_readCompletionGeneration;
    g_dispatcher.deferEvent([weakConnection, generation] {
        if (const auto connection = weakConnection.lock(); connection && connection->m_readCompletionPending &&
            connection->m_readCompletionGeneration == generation) {
            connection->m_readCompletionPending = false;
            connection->tryCompleteRead();
        }
    });
}

void WebConnection::tryCompleteRead()
{
    if (!m_recvCallback || m_inputStream.size() < m_pendingReadSize)
        return;

    if (m_readTimeoutEvent) {
        m_readTimeoutEvent->cancel();
        m_readTimeoutEvent = nullptr;
    }

    const uint16_t readSize = m_pendingReadSize;
    m_pendingReadSize = 0;
    const auto callback = std::exchange(m_recvCallback, nullptr);
    std::vector<uint8_t> data(readSize);
    std::istream stream(&m_inputStream);
    stream.read(reinterpret_cast<char*>(data.data()), readSize);
    releaseBufferedBytes(readSize);
    m_activityTimer.restart();
    callback(data.data(), readSize);

    if (m_remoteErrorPending && m_websocket > 0)
        finishDeferredError();
}

int WebConnection::getIp()
{
    g_logger.error("Getting remote ip");
    return 0;
}

#endif
