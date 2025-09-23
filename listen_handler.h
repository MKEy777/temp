#pragma once

#include "event_handler.h"
#include "sock_handler.h"
#include "reactor.h"

class ListenHandler : public EventHandler {
private:
    Handle listen_fd;
    sockaddr_in addr;
    Reactor* sub_reactor;

public:
    ListenHandler(int port, Reactor* sub);
    ~ListenHandler();

    Handle get_handle() const override;
    void handle_read() override;
    void handle_write() override;
    void handle_error() override;
    void handle_close() override;

private:
    void set_non_blocking(Handle fd);
};