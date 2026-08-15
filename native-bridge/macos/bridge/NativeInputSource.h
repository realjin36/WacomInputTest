#pragma once

#include "BoundedQueue.h"
#include "BridgeTypes.h"

#include <memory>

class NativeInputSource {
public:
    NativeInputSource();
    ~NativeInputSource();

    NativeInputSource(const NativeInputSource&) = delete;
    NativeInputSource& operator=(const NativeInputSource&) = delete;

    bool Start();
    void PumpAppEvent(double timeoutSeconds);
    void Stop();

    BoundedQueue<NativeInputEvent>& Events();
    NativeStatusSnapshot Status() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

