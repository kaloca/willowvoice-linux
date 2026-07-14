#include <KGlobalAccel>

#include <QAction>
#include <QCommandLineOption>
#include <QCommandLineParser>
#include <QCoreApplication>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QKeySequence>
#include <QLockFile>
#include <QProcess>
#include <QStandardPaths>
#include <QTimer>

#include <utility>

#ifndef WILLOW_BRIDGE_VERSION
#define WILLOW_BRIDGE_VERSION "development"
#endif

namespace {

class BridgeController final : public QObject
{
public:
    explicit BridgeController(QString bridgePath, int maximumRecordingSeconds, QObject *parent = nullptr)
        : QObject(parent)
        , bridgePath_(std::move(bridgePath))
    {
        process_.setProgram(bridgePath_);
        process_.setStandardOutputFile(QProcess::nullDevice());
        process_.setStandardErrorFile(QProcess::nullDevice());

        commandTimeout_.setSingleShot(true);
        maximumRecording_.setSingleShot(true);
        maximumRecording_.setInterval(maximumRecordingSeconds * 1000);

        connect(&commandTimeout_, &QTimer::timeout, this, [this]() {
            timedOut_ = true;
            process_.kill();
            if (process_.state() == QProcess::NotRunning) {
                const quint64 serial = commandSerial_;
                QTimer::singleShot(0, this,
                                   [this, serial]() { completeCommand(false, serial); });
            }
        });
        connect(&maximumRecording_, &QTimer::timeout, this, [this]() {
            qWarning() << "maximum recording duration reached; releasing Willow shortcut";
            desiredRecording_ = false;
            failedAttempts_ = 0;
            reconcile();
        });

        // Clear a key that could have remained held after a crash or logout.
        resetRequired_ = true;
        reconcile();
    }

    void setShortcutHeld(bool held)
    {
        if (desiredRecording_ == held) {
            return;
        }
        desiredRecording_ = held;
        failedAttempts_ = 0;
        if (!held) {
            maximumRecording_.stop();
        }
        reconcile();
    }

private:
    void reconcile()
    {
        if (commandRunning_ || failedAttempts_ >= maximumAttempts_) {
            return;
        }
        if (resetRequired_) {
            launch(QStringLiteral("reset"));
            return;
        }
        if (actualRecording_ != desiredRecording_) {
            launch(desiredRecording_ ? QStringLiteral("start") : QStringLiteral("stop"));
        }
    }

    void launch(const QString &command)
    {
        if (process_.state() != QProcess::NotRunning) {
            qWarning() << "bridge process had not stopped; delaying reconciliation";
            QTimer::singleShot(100, this, [this]() { reconcile(); });
            return;
        }
        commandRunning_ = true;
        runningCommand_ = command;
        timedOut_ = false;
        const quint64 serial = ++commandSerial_;
        finishedConnection_ = connect(
            &process_, qOverload<int, QProcess::ExitStatus>(&QProcess::finished), this,
            [this, serial](int exitCode, QProcess::ExitStatus exitStatus) {
                completeCommand(!timedOut_ && exitCode == 0
                                    && exitStatus == QProcess::NormalExit,
                                serial);
            });
        errorConnection_ = connect(
            &process_, &QProcess::errorOccurred, this,
            [this, serial](QProcess::ProcessError error) {
                if (error == QProcess::FailedToStart) {
                    QTimer::singleShot(0, this,
                                       [this, serial]() { completeCommand(false, serial); });
                }
            });
        process_.setArguments({command});
        process_.start();
        commandTimeout_.setInterval(command == QStringLiteral("start") ? 40000 : 5000);
        commandTimeout_.start();
    }

    void completeCommand(bool success, quint64 serial)
    {
        if (!commandRunning_ || serial != commandSerial_
            || process_.state() != QProcess::NotRunning) {
            return;
        }

        commandRunning_ = false;
        commandTimeout_.stop();
        disconnect(finishedConnection_);
        disconnect(errorConnection_);
        const QString completed = std::exchange(runningCommand_, QString());

        if (success) {
            if (completed == QStringLiteral("reset")) {
                actualRecording_ = false;
                resetRequired_ = false;
            } else if (completed == QStringLiteral("start")) {
                actualRecording_ = true;
                failedAttempts_ = 0;
                maximumRecording_.start();
            } else if (completed == QStringLiteral("stop")) {
                actualRecording_ = false;
                failedAttempts_ = 0;
                maximumRecording_.stop();
            }
        } else {
            ++failedAttempts_;
            resetRequired_ = true;
            actualRecording_ = false;
            maximumRecording_.stop();
            qWarning().noquote() << "Willow bridge command failed:" << completed
                                 << "attempt" << failedAttempts_ << "of" << maximumAttempts_;
        }

        if (failedAttempts_ >= maximumAttempts_) {
            qCritical() << "Willow bridge failed repeatedly; exiting for systemd safety recovery";
            QCoreApplication::exit(1);
            return;
        }
        QTimer::singleShot(success ? 0 : 250, this, [this]() { reconcile(); });
    }

    static constexpr int maximumAttempts_ = 3;
    QString bridgePath_;
    QProcess process_;
    QTimer commandTimeout_;
    QTimer maximumRecording_;
    QMetaObject::Connection finishedConnection_;
    QMetaObject::Connection errorConnection_;
    QString runningCommand_;
    quint64 commandSerial_ = 0;
    int failedAttempts_ = 0;
    bool commandRunning_ = false;
    bool timedOut_ = false;
    bool desiredRecording_ = false;
    bool actualRecording_ = false;
    bool resetRequired_ = false;
};

} // namespace

int main(int argc, char *argv[])
{
    QCoreApplication::setApplicationName(QStringLiteral("willow-dictate-ptt"));
    QCoreApplication::setApplicationVersion(QStringLiteral(WILLOW_BRIDGE_VERSION));
    QGuiApplication::setDesktopFileName(QStringLiteral("willow-dictate-ptt"));

    QGuiApplication app(argc, argv);
    app.setApplicationDisplayName(QStringLiteral("Willow Push-to-Talk"));
    app.setQuitOnLastWindowClosed(false);

    QCommandLineParser parser;
    parser.setApplicationDescription(
        QStringLiteral("KDE hold/release shortcut helper for Willow Voice under Wine"));
    parser.addHelpOption();
    parser.addVersionOption();
    const QCommandLineOption bridgeOption(
        QStringLiteral("bridge"), QStringLiteral("Path to the willow-dictate bridge script."),
        QStringLiteral("path"),
        QCoreApplication::applicationDirPath() + QStringLiteral("/willow-dictate"));
    const QCommandLineOption maximumOption(
        QStringLiteral("maximum-recording-seconds"),
        QStringLiteral("Safety limit for one held recording."), QStringLiteral("seconds"),
        QStringLiteral("600"));
    const QCommandLineOption unregisterOption(
        QStringLiteral("unregister"),
        QStringLiteral("Remove this component from KDE's global shortcut registry."));
    parser.addOption(bridgeOption);
    parser.addOption(maximumOption);
    parser.addOption(unregisterOption);
    parser.process(app);

    if (parser.isSet(unregisterOption)) {
        KGlobalAccel::cleanComponent(QStringLiteral("willow-dictate-ptt"));
        return 0;
    }

    bool maximumOk = false;
    const int maximumSeconds = parser.value(maximumOption).toInt(&maximumOk);
    if (!maximumOk || maximumSeconds < 30 || maximumSeconds > 3600) {
        qCritical() << "maximum recording duration must be between 30 and 3600 seconds";
        return 2;
    }

    const QString bridgePath = QFileInfo(parser.value(bridgeOption)).absoluteFilePath();
    const QFileInfo bridgeInfo(bridgePath);
    if (!bridgeInfo.isFile() || !bridgeInfo.isExecutable()) {
        qCritical().noquote() << "bridge script is not executable:" << bridgePath;
        return 1;
    }

    const QString runtimeBase = QStandardPaths::writableLocation(QStandardPaths::RuntimeLocation);
    if (runtimeBase.isEmpty()) {
        qCritical() << "XDG_RUNTIME_DIR is unavailable";
        return 1;
    }
    const QString runtimeDirectory = runtimeBase + QStringLiteral("/willow-linux-bridge");
    if (!QDir().mkpath(runtimeDirectory)) {
        qCritical().noquote() << "cannot create runtime directory:" << runtimeDirectory;
        return 1;
    }
    QFile::setPermissions(runtimeDirectory,
                          QFileDevice::ReadOwner | QFileDevice::WriteOwner
                              | QFileDevice::ExeOwner);

    QLockFile instanceLock(runtimeDirectory + QStringLiteral("/ptt-instance.lock"));
    instanceLock.setStaleLockTime(5000);
    if (!instanceLock.tryLock(0) && !instanceLock.removeStaleLockFile()) {
        qCritical() << "another Willow push-to-talk helper is already running";
        return 1;
    }
    if (!instanceLock.isLocked() && !instanceLock.tryLock(0)) {
        qCritical() << "could not acquire the Willow push-to-talk instance lock";
        return 1;
    }

    BridgeController controller(bridgePath, maximumSeconds);

    QAction dictateAction(&app);
    dictateAction.setObjectName(QStringLiteral("dictate"));
    dictateAction.setText(QStringLiteral("Hold to dictate"));
    dictateAction.setProperty("componentName", QStringLiteral("willow-dictate-ptt"));
    dictateAction.setProperty("componentDisplayName", QStringLiteral("Willow Push-to-Talk"));
    dictateAction.setAutoRepeat(false);

    const QKeySequence shortcut(Qt::META | Qt::ALT | Qt::Key_D);
    auto *globalAccel = KGlobalAccel::self();
    const bool defaultRegistered = globalAccel->setDefaultShortcut(&dictateAction, {shortcut});
    const bool shortcutRegistered = globalAccel->setShortcut(&dictateAction, {shortcut});
    if (!defaultRegistered || !shortcutRegistered
        || globalAccel->shortcut(&dictateAction).isEmpty()) {
        qWarning() << "KDE did not register the default shortcut; configure it in System Settings";
    }

    QObject::connect(globalAccel, &KGlobalAccel::globalShortcutActiveChanged, &dictateAction,
                     [&dictateAction, &controller](QAction *changedAction, bool active) {
                         if (changedAction == &dictateAction) {
                             controller.setShortcutHeld(active);
                         }
                     });

    return app.exec();
}
