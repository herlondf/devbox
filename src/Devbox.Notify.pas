unit Devbox.Notify;

{ Aviso fora da janela (balão da bandeja). O form principal liga o tratador;
  as telas só chamam Notify. }

interface

uses
  System.SysUtils;

type
  TNotifyProc = reference to procedure(const ATitle, AText: string; AError: Boolean);

var
  NotifyHandler: TNotifyProc;

procedure Notify(const ATitle, AText: string; AError: Boolean = False);

implementation

uses
  Devbox.Focus;

procedure Notify(const ATitle, AText: string; AError: Boolean);
begin
  // Em foco, o aviso espera na fila e sai junto no fim.
  if FocusActive and FocusMuteNotify then
  begin
    FocusQueue := FocusQueue + [ATitle + ': ' + AText];
    Exit;
  end;
  if Assigned(NotifyHandler) then
    NotifyHandler(ATitle, AText, AError);
end;

end.
