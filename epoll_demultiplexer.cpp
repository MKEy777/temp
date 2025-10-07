#include "epoll_demultiplexer.h"
#include "event_handler.h"
#include <unistd.h>
#include <iostream>

EpollDemultiplexer::EpollDemultiplexer() : events(1024) {
    epoll_fd = epoll_create1(0);
    if (epoll_fd < 0) {
        perror("epoll_create1 failed");
    }
}

EpollDemultiplexer::~EpollDemultiplexer() {
    if (epoll_fd > 0) {
        close(epoll_fd);
    }
}

bool EpollDemultiplexer::regist(Handle handle, Event evt) {
    struct epoll_event event;
    event.data.fd = handle;
    event.events = 0; // 清零

    if (evt & READ) {
        event.events |= EPOLLIN;
    }
    if (evt & WRITE) {
        event.events |= EPOLLOUT;
    }

    // 关键：设置为边缘触发模式
    event.events |= EPOLLET;

    if (epoll_ctl(epoll_fd, EPOLL_CTL_ADD, handle, &event) < 0) {
        perror("epoll_ctl ADD failed");
        return false;
    }
    std::cout << "Registered FD: " << handle << " with epoll for events: " << evt << std::endl;
    return true;
}

bool EpollDemultiplexer::modify(Handle handle, Event evt) {
    struct epoll_event event;
    event.data.fd = handle;
    event.events = 0;

    if (evt & READ) {
        event.events |= EPOLLIN;
    }
    if (evt & WRITE) {
        event.events |= EPOLLOUT;
    }
    event.events |= EPOLLET;

    if (epoll_ctl(epoll_fd, EPOLL_CTL_MOD, handle, &event) < 0) {
        perror("epoll_ctl MOD failed");
        return false;
    }
    std::cout << "Modified FD: " << handle << " for events: " << evt << std::endl;
    std::cout << "----------------------------------------- " << std::endl;
    return true;
}

bool EpollDemultiplexer::remove(Handle handle) {
    if (epoll_ctl(epoll_fd, EPOLL_CTL_DEL, handle, nullptr) < 0) {
        perror("epoll_ctl DEL failed");
        return false;
    }
    return true;
}

int EpollDemultiplexer::wait_event(std::map<Handle, EventHandler*>& handlers, int timeout) {
    int num_events = epoll_wait(epoll_fd, events.data(), static_cast<int>(events.size()), timeout);

    if (num_events < 0) {
        perror("epoll_wait failed");
        return 0;
    }

    for (int i = 0; i < (int)num_events; ++i) {
        Handle fd = events[i].data.fd;
        auto it = handlers.find(fd);
        if (it == handlers.end()) continue;
        EventHandler* handler = it->second;

        if (events[i].events & (EPOLLERR | EPOLLHUP)) {
            handler->handle_error();
        }
        else {
            if (events[i].events & EPOLLIN) {
                handler->handle_read();
            }
            if (events[i].events & EPOLLOUT) {
                handler->handle_write();
            }
        }
    }

    // 如果事件数组满了，进行扩容
    if (num_events == static_cast<int>(events.size())) {
        events.resize(events.size() * 2);
    }

    return (int)num_events;
}