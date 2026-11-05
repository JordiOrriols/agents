import React, { useState } from "react";
import { useTranslation } from "react-i18next";
import { AppFooter, ProjectIcon, WelcomeScreen } from "@jordiorriols/ui";
import { Gauge, ListTodo, MessagesSquare } from "@jordiorriols/ui/icons";
import { LoginDialog } from "@/components/LoginDialog";
import { useData } from "@/data/DataProvider";

export function WelcomePage() {
  const { t, i18n } = useTranslation();
  const { authEnabled, authError, linkError } = useData();
  const [mode, setMode] = useState<"signIn" | "signUp">("signIn");
  const [open, setOpen] = useState(false);
  const openDialog = (next: "signIn" | "signUp") => {
    setMode(next);
    setOpen(true);
  };
  return (
    <>
      <WelcomeScreen
        projectId="agents"
        brand={t("app.name")}
        icon={<ProjectIcon projectId="agents" />}
        title={t("welcome.title")}
        description={t("welcome.description")}
        features={[
          { icon: <ListTodo />, label: t("welcome.queue") },
          { icon: <Gauge />, label: t("welcome.usage") },
          { icon: <MessagesSquare />, label: t("welcome.chat") },
        ]}
        signInLabel={t("auth.signIn")}
        signUpLabel={t("auth.signUp")}
        disabled={!authEnabled}
        onSignIn={() => openDialog("signIn")}
        onSignUp={() => openDialog("signUp")}
        notice={
          <>
            {authError && <p role="alert">{authError}</p>}
            {linkError && <p role="alert">{t("auth.linkFailed", { message: linkError })}</p>}
            {!authEnabled && <p role="alert">{t("welcome.authUnavailable")}</p>}
          </>
        }
      >
        <LoginDialog isOpen={open} initialMode={mode} onClose={() => setOpen(false)} />
      </WelcomeScreen>
      <AppFooter projectId="agents" language={i18n.language} />
    </>
  );
}
