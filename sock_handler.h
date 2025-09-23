#pragma once

#include "event_handler.h"
#include "reactor.h"
#include "thread_pool.h"
#include <string>
#include <mutex>

extern ThreadPool* thread_pool;

class SockHandler : public EventHandler {
private:
    Handle sock_fd;
    char read_buf[1024];
    std::string write_buf;
    std::mutex buf_mutex;
    Reactor* reactor;  // µ±Ç°Reactor

public:
    SockHandler(Handle fd, Reactor* r);
    ~SockHandler();

    Handle get_handle() const override;
    void handle_read() override;
    void handle_write() override;
    void handle_error() override;
    void handle_close() override;
};

