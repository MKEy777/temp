#include "clientwindow.h"
#include "ui_clientwindow.h"
#include <QDateTime>

ClientWindow::ClientWindow(const QString& username, const QString& server_ip, QWidget *parent) :
    QWidget(parent),
    ui(new Ui::ClientWindow),
    username_(username)
{
    ui->setupUi(this);
    this->setWindowTitle("Qt Chat Client"); // Set the window title

    network_manager_ = new NetworkManager(this);

    // 1. Connect signals from NetworkManager to this window's slots
    connect(network_manager_, SIGNAL(connected()),
            this, SLOT(handle_connected()));

    connect(network_manager_, SIGNAL(disconnected()),
            this, SLOT(handle_disconnected()));

    connect(network_manager_, SIGNAL(chat_message_received(QString,QString)),
            this, SLOT(handle_chat_message(QString,QString)));

    connect(network_manager_, SIGNAL(user_list_updated(QStringList)),
            this, SLOT(handle_user_list(QStringList)));

    connect(network_manager_, SIGNAL(system_notification_received(QString)),
            this, SLOT(handle_system_notification(QString)));

    connect(network_manager_, SIGNAL(connection_error(QString)),
            this, SLOT(handle_connection_error(QString)));

    // 2. Connect signals from UI widgets to this window's slots
    connect(ui->sendButton, SIGNAL(clicked()),
            this, SLOT(on_sendButton_clicked()));

    connect(ui->messageLineEdit, SIGNAL(returnPressed()),
            this, SLOT(on_messageLineEdit_returnPressed()));

    // 3. Automatically try to connect to the server before the constructor ends
    append_message("[System] Connecting to server at " + server_ip + "...");
    network_manager_->connect_to_server(server_ip, 9527); // Port number is 9527
}

ClientWindow::~ClientWindow()
{
    delete ui;
}

// --- Implementation of the slot functions ---

void ClientWindow::handle_connected()
{
    append_message("[System] Connected successfully!");
    // Immediately send a login request to tell the server our nickname
    network_manager_->send_login_request(username_);
}

void ClientWindow::handle_disconnected()
{
    append_message("[System] Disconnected from server.");
    // Disable UI controls like the send button
    ui->sendButton->setEnabled(false);
    ui->messageLineEdit->setEnabled(false);
}

void ClientWindow::handle_connection_error(const QString& error_message)
{
    append_message("[Error] Connection failed: " + error_message);
}

void ClientWindow::handle_chat_message(const QString& username, const QString& text)
{
    QString time = QDateTime::currentDateTime().toString("hh:mm:ss");
    append_message(QString("[%1] %2: %3").arg(time, username, text));
}

void ClientWindow::handle_system_notification(const QString& message)
{
    append_message(QString("[System] %1").arg(message));
}

void ClientWindow::handle_user_list(const QStringList& users)
{
    ui->userListWidget->clear();
    ui->userListWidget->addItems(users);
}

void ClientWindow::on_sendButton_clicked()
{
    QString text = ui->messageLineEdit->text().trimmed(); // Trim whitespace
    if (!text.isEmpty()) {
        network_manager_->send_chat_message(text);
        ui->messageLineEdit->clear();
        ui->messageLineEdit->setFocus(); // Keep the input field in focus
    }
}

void ClientWindow::on_messageLineEdit_returnPressed()
{
    on_sendButton_clicked();
}

void ClientWindow::append_message(const QString& message)
{
    ui->chatHistoryTextEdit->append(message);
}
