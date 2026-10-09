program Devbox;

uses
  Winapi.Windows,
  System.SysUtils,
  System.Hash,
  Vcl.Forms,
  UI.Runtime.Vcl,
  Devbox.Model in 'Devbox.Model.pas',
  Devbox.Store in 'Devbox.Store.pas',
  Devbox.Sys in 'Devbox.Sys.pas',
  Devbox.Secrets in 'Devbox.Secrets.pas',
  Devbox.Convert in 'Devbox.Convert.pas',
  Devbox.Cleanup in 'Devbox.Cleanup.pas',
  Devbox.Jobs in 'Devbox.Jobs.pas',
  Devbox.Net in 'Devbox.Net.pas',
  Devbox.Envs in 'Devbox.Envs.pas',
  Devbox.Focus in 'Devbox.Focus.pas',
  Devbox.Tools in 'Devbox.Tools.pas',
  Devbox.AI in 'Devbox.AI.pas',
  Devbox.SysInfo in 'Devbox.SysInfo.pas',
  Devbox.Notify in 'Devbox.Notify.pas',
  Devbox.Helper in 'Devbox.Helper.pas',
  Devbox.UI.Kit in 'Devbox.UI.Kit.pas',
  Devbox.UI.DialogBase in 'Devbox.UI.DialogBase.pas',
  Devbox.UI.Dialogs in 'Devbox.UI.Dialogs.pas',
  Devbox.UI.Clipboard in 'Devbox.UI.Clipboard.pas',
  Devbox.UI.Expander in 'Devbox.UI.Expander.pas',
  Devbox.UI.Focus in 'Devbox.UI.Focus.pas',
  Devbox.UI.Pomodoro in 'Devbox.UI.Pomodoro.pas',
  Devbox.UI.SidePeek in 'Devbox.UI.SidePeek.pas',
  Devbox.UI.HostPage in 'Devbox.UI.HostPage.pas',
  Devbox.UI.Tools in 'Devbox.UI.Tools.pas',
  Devbox.UI.Services in 'Devbox.UI.Services.pas',
  Devbox.UI.Cleanup in 'Devbox.UI.Cleanup.pas',
  Devbox.UI.Network in 'Devbox.UI.Network.pas',
  Devbox.UI.System in 'Devbox.UI.System.pas',
  Devbox.UI.Envs in 'Devbox.UI.Envs.pas',
  Devbox.UI.Jobs in 'Devbox.UI.Jobs.pas',
  Devbox.UI.Watches in 'Devbox.UI.Watches.pas',
  Devbox.UI.Settings in 'Devbox.UI.Settings.pas',
  Devbox.UI.AISettings in 'Devbox.UI.AISettings.pas',
  Devbox.Google in 'Devbox.Google.pas',
  Devbox.ICal in 'Devbox.ICal.pas',
  Devbox.Tls in 'Devbox.Tls.pas',
  Devbox.Imap in 'Devbox.Imap.pas',
  Devbox.MailSource in 'Devbox.MailSource.pas',
  Devbox.Whisper in 'Devbox.Whisper.pas',
  Devbox.I18n.En in 'Devbox.I18n.En.pas',
  Devbox.I18n in 'Devbox.I18n.pas',
  Devbox.Issues.Model in 'Devbox.Issues.Model.pas',
  Devbox.Issues.Providers in 'Devbox.Issues.Providers.pas',
  Devbox.Issues.Diff in 'Devbox.Issues.Diff.pas',
  Devbox.Issues.Store in 'Devbox.Issues.Store.pas',
  Devbox.Issues.TrayIcon in 'Devbox.Issues.TrayIcon.pas',
  Devbox.Issues.AI in 'Devbox.Issues.AI.pas',
  Devbox.Issues.Backup in 'Devbox.Issues.Backup.pas',
  Devbox.Issues.Update in 'Devbox.Issues.Update.pas',
  Devbox.Issues.UI.Common in 'Devbox.Issues.UI.Common.pas',
  Devbox.Issues.UI.Notify in 'Devbox.Issues.UI.Notify.pas',
  Devbox.Issues.UI.Status in 'Devbox.Issues.UI.Status.pas',
  Devbox.Issues.UI.Tags in 'Devbox.Issues.UI.Tags.pas',
  Devbox.Issues.UI.Account in 'Devbox.Issues.UI.Account.pas',
  Devbox.Issues.UI.Detail in 'Devbox.Issues.UI.Detail.pas',
  Devbox.Issues.UI.Views in 'Devbox.Issues.UI.Views.pas',
  Devbox.Issues.UI.Mini in 'Devbox.Issues.UI.Mini.pas',
  Devbox.Issues.UI.Main in 'Devbox.Issues.UI.Main.pas',
  Devbox.Usage in 'Devbox.Usage.pas',
  Devbox.WebRtcAec in 'Devbox.WebRtcAec.pas',
  Devbox.WebSocket in 'Devbox.WebSocket.pas',
  Devbox.Realtime in 'Devbox.Realtime.pas',
  Devbox.Speech in 'Devbox.Speech.pas',
  Devbox.Vosk in 'Devbox.Vosk.pas',
  Devbox.Voice in 'Devbox.Voice.pas',
  Devbox.Voice.Agent in 'Devbox.Voice.Agent.pas',
  Devbox.UI.Voice in 'Devbox.UI.Voice.pas',
  Devbox.UI.Google in 'Devbox.UI.Google.pas',
  Devbox.UI.Mail in 'Devbox.UI.Mail.pas',
  Devbox.UI.Agenda in 'Devbox.UI.Agenda.pas',
  Devbox.UI.Digest in 'Devbox.UI.Digest.pas',
  Devbox.UI.Main in 'Devbox.UI.Main.pas';

var
  Mutex: THandle;

begin
  // Uma instância por pasta de dados: o mesmo usuário pode rodar outra cópia
  // com LOCALAPPDATA diferente (teste) sem a trava barrar.
  Mutex := CreateMutex(nil, True, PChar('Local\Devbox.' +
    StringReplace(GetEnvironmentVariable('USERDOMAIN') + '.' + GetEnvironmentVariable('USERNAME'),
      '\', '.', [rfReplaceAll]) + '.' + THashMD5.GetHashString(LowerCase(GetEnvironmentVariable('LOCALAPPDATA')))));
  if GetLastError = ERROR_ALREADY_EXISTS then
  begin
    PostMessage(FindWindow('TMainForm', PChar('Devbox ' + AppVersion)),
      RegisterWindowMessage(ShowMessageName), 0, 0);
    Exit;
  end;
  try
    Application.Initialize;
    Application.ShowMainForm := False;
    Application.Title := 'Devbox';
    Application.CreateForm(TMainForm, MainForm);
    if FindCmdLineSwitch('show') then
      MainForm.Show;
    Application.Run;
  finally
    CloseHandle(Mutex);
  end;
end.
