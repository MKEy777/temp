#pragma once
#include "epoll_demultiplexer.h"
#include "event_handler.h"
#include <map>
#include <mutex>
#include <vector>
#include <functional>

class ReactorImplementation {
private:
    EventDemultiplexer* demux;
    std::map<Handle, EventHandler*> handlers;
    std::mutex handlers_mutex;
    bool running_; // 运行状态

    // --- eventfd 相关 ---
    int wakeup_fd_;
    EventHandler* wakeup_handler_;
    void handle_wakeup();
    // --------------------

    std::mutex tasks_mutex_;
    std::vector<std::function<void()>> pending_tasks_;
    void do_pending_tasks();

public:
    ReactorImplementation();
    ~ReactorImplementation();

    void regist(EventHandler* handler, Event evt);
    void remove(Handle fd);
    void modify(Handle fd, Event evt);
    void event_loop();
    void quit(); // 退出事件循环

    void queue_in_loop(std::function<void()> task);
};