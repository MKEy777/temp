#include "reactor_impl.h"
#include "reactor.h"
#include <iostream>
#include <unistd.h>
#include <sys/eventfd.h>

// Ϊ wakeup_fd_ ����һ��ר�ŵġ��򵥵��¼�������
class WakeupHandler : public EventHandler {
public:
    WakeupHandler(int fd) : fd_(fd) {}
    Handle get_handle() const override { return fd_; }
    void handle_read() override {
        uint64_t one;
        // ��ȡfd��ʹ����������㣬����epoll��һֱ֪ͨ
        ssize_t n = read(fd_, &one, sizeof one);
        if (n != sizeof one) {
            perror("WakeupHandler read failed");
        }
        std::cout << "[DEBUG] Reactor: Woken up by eventfd." << std::endl;
    }
    void handle_write() override {}
    void handle_error() override {}
    // ��Reactor����ʱ�����handler�ᱻdelete
    void handle_close() override {}
private:
    int fd_;
};

ReactorImplementation::ReactorImplementation()
    : demux(new EpollDemultiplexer()), running_(true), wakeup_fd_(eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC)) {
    if (wakeup_fd_ < 0) {
        perror("eventfd create failed");
    }
    std::cout << "[DEBUG] Reactor: eventfd created with fd " << wakeup_fd_ << std::endl;
    // ����WakeupHandler������ע�ᵽReactor��
    wakeup_handler_ = new WakeupHandler(wakeup_fd_);
    regist(wakeup_handler_, READ);
}

ReactorImplementation::~ReactorImplementation() {
    // regist/remove ���� handlers_ map �Ĺ���, ����ֻ�� delete demux
    // ע�⣺�������Դ����������ø����ƣ�ȷ������handler����ɾ��
    delete demux;
    close(wakeup_fd_);
    delete wakeup_handler_;
}

// ... regist, remove, modify, do_pending_tasks ���ֲ��� ...
void ReactorImplementation::regist(EventHandler* handler, Event evt) {
    std::lock_guard<std::mutex> lock(handlers_mutex);
    Handle fd = handler->get_handle();
    handlers[fd] = handler;
    demux->regist(fd, evt);
}
void ReactorImplementation::remove(Handle fd) {
    std::lock_guard<std::mutex> lock(handlers_mutex);
    auto it = handlers.find(fd);
    if (it != handlers.end()) {
        demux->remove(fd);
        it->second->handle_close();
        delete it->second;
        handlers.erase(it);
    }
}
void ReactorImplementation::modify(Handle fd, Event evt) {
    std::lock_guard<std::mutex> lock(handlers_mutex);
    demux->modify(fd, evt);
}
void ReactorImplementation::do_pending_tasks() {
    std::vector<std::function<void()>> tasks;
    {
        std::lock_guard<std::mutex> lock(tasks_mutex_);
        if (pending_tasks_.empty()) return;
        tasks.swap(pending_tasks_);
    }
    std::cout << "[DEBUG] Reactor: Executing " << tasks.size() << " pending tasks." << std::endl;
    for (const auto& task : tasks) {
        task();
    }
}


void ReactorImplementation::event_loop() {
    std::cout << "[DEBUG] Reactor: Starting event loop..." << std::endl;
    while (running_) {
        demux->wait_event(handlers, -1);
        do_pending_tasks();
    }
    std::cout << "[DEBUG] Reactor: Event loop finished." << std::endl;
}

void ReactorImplementation::quit() {
    running_ = false;
    uint64_t one = 1;
    ssize_t n = write(wakeup_fd_, &one, sizeof one);
    if (n != sizeof one) {
        perror("write to wakeup_fd_ failed");
    }
}

void ReactorImplementation::queue_in_loop(std::function<void()> task) {
    {
        std::lock_guard<std::mutex> lock(tasks_mutex_);
        pending_tasks_.push_back(std::move(task));
    }
    uint64_t one = 1;
    ssize_t n = write(wakeup_fd_, &one, sizeof one);
    if (n != sizeof one) {
        perror("write to wakeup_fd_ failed in queue_in_loop");
    }
}

// ... Reactor ���ʵ�ֱ��ֲ��� ...
Reactor::Reactor() : impl(new ReactorImplementation()) {}
Reactor::~Reactor() { delete impl; }
void Reactor::regist(EventHandler* handler, Event evt) { impl->regist(handler, evt); }
void Reactor::remove(Handle fd) { impl->remove(fd); }
void Reactor::modify(Handle fd, Event evt) { impl->modify(fd, evt); }
void Reactor::event_loop() { impl->event_loop(); }
void Reactor::quit() { impl->quit(); }
void Reactor::queue_in_loop(std::function<void()> task) { impl->queue_in_loop(std::move(task)); }