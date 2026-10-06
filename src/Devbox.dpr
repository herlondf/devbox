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
  Devbox.UI.Tools in 'Devbox.UI.Tools.pas',
  Devbox.UI.Services in 'Devbox.UI.Services.pas',
  Devbox.UI.Cleanup in 'Devbox.UI.Cleanup.pas',
  Devbox.UI.Network in 'Devbox.UI.Network.pas',
  Devbox.UI.System in 'Devbox.UI.System.pas',
  Devbox.UI.Envs in 'Devbox.UI.Envs.pas',
  Devbox.UI.AICommand in 'Devbox.UI.AICommand.pas',
  Devbox.UI.Jobs in 'Devbox.UI.Jobs.pas',
  Devbox.UI.Watches in 'Devbox.UI.Watches.pas',
  Devbox.UI.Settings in 'Devbox.UI.Settings.pas',
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
