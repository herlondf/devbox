program DevboxHelper;

{ Ajudante do Devbox: expansor de texto (gancho de teclado) e captura de tela.
  Fica separado do Devbox.exe: juntos no mesmo exe, o antivírus via cara de
  keylogger e apagava o app. Abre pelo Devbox.exe e fecha junto com ele. }

uses
  Winapi.Windows,
  System.SysUtils,
  System.Hash,
  Vcl.Forms,
  UI.Runtime.Vcl,
  Devbox.Model in 'Devbox.Model.pas',
  Devbox.Store in 'Devbox.Store.pas',
  Devbox.Sys in 'Devbox.Sys.pas',
  Devbox.Keys in 'Devbox.Keys.pas',
  Devbox.Helper in 'Devbox.Helper.pas',
  Devbox.UI.Kit in 'Devbox.UI.Kit.pas',
  Devbox.UI.DialogBase in 'Devbox.UI.DialogBase.pas',
  Devbox.UI.Capture in 'Devbox.UI.Capture.pas',
  Devbox.Helper.Main in 'Devbox.Helper.Main.pas';

var
  Mutex: THandle;

begin
  Mutex := CreateMutex(nil, True, PChar('Local\' + HelperCaption));
  if GetLastError = ERROR_ALREADY_EXISTS then
    Exit;
  try
    Application.Initialize;
    Application.ShowMainForm := False;
    Application.MainFormOnTaskbar := False;
    Application.Title := 'Devbox (ajudante)';
    Application.CreateForm(THelperForm, HelperForm);
    Application.Run;
  finally
    CloseHandle(Mutex);
  end;
end.
