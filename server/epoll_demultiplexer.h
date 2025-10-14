#pragma once
#include "event_demultiplexer.h"
#include <vector>
#include <sys/epoll.h>

class EpollDemultiplexer : public EventDemultiplexer {
public:
    EpollDemultiplexer();
    ~EpollDemultiplexer() override;

    int wait_event(std::map<Handle, EventHandler*>& handlers, int timeout = 0) override;
    bool regist(Handle handle, Event evt) override;
    bool modify(Handle handle, Event evt) override;
    bool remove(Handle handle) override;

private:
    int epoll_fd;
    std::vector<struct epoll_event> events;
};

