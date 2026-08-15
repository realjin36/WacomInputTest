#pragma once

#include <cstdint>
#include <memory>
#include <string>

class NativeInputSource;

struct ServerStatusSnapshot {
    std::uint64_t webSocketClients = 0;
    std::uint64_t activeBrowserClients = 0;
    std::uint64_t broadcastEvents = 0;
    std::uint64_t droppedClientMessages = 0;
};

class LocalServer {
public:
    LocalServer(NativeInputSource& input, std::uint16_t port, std::string webRoot);
    ~LocalServer();

    LocalServer(const LocalServer&) = delete;
    LocalServer& operator=(const LocalServer&) = delete;

    bool Start();
    void Stop();
    ServerStatusSnapshot Status() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

