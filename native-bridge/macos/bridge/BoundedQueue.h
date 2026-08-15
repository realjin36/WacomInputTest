#pragma once

#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <utility>
#include <vector>

template <typename T>
class BoundedQueue {
public:
    explicit BoundedQueue(std::size_t capacity)
        : buffer_(capacity) {}

    bool Push(T value) {
        bool dropped = false;
        {
            std::lock_guard lock(mutex_);
            if (stopped_) {
                return false;
            }
            if (count_ == buffer_.size()) {
                readIndex_ = (readIndex_ + 1) % buffer_.size();
                --count_;
                ++dropped_;
                dropped = true;
            }
            buffer_[writeIndex_] = std::move(value);
            writeIndex_ = (writeIndex_ + 1) % buffer_.size();
            ++count_;
        }
        available_.notify_one();
        return !dropped;
    }

    bool Pop(T& value) {
        std::unique_lock lock(mutex_);
        available_.wait(lock, [this] { return stopped_ || count_ > 0; });
        if (count_ == 0) {
            return false;
        }
        value = std::move(buffer_[readIndex_]);
        readIndex_ = (readIndex_ + 1) % buffer_.size();
        --count_;
        return true;
    }

    void Stop() {
        {
            std::lock_guard lock(mutex_);
            stopped_ = true;
        }
        available_.notify_all();
    }

    std::uint64_t Dropped() const {
        std::lock_guard lock(mutex_);
        return dropped_;
    }

private:
    mutable std::mutex mutex_;
    std::condition_variable available_;
    std::vector<T> buffer_;
    std::size_t readIndex_ = 0;
    std::size_t writeIndex_ = 0;
    std::size_t count_ = 0;
    std::uint64_t dropped_ = 0;
    bool stopped_ = false;
};

