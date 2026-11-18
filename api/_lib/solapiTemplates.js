// 알림톡 타입 → 솔라피 templateId 매핑. 템플릿 검수 통과 후 SOLAPI_TEMPLATE_IDS(JSON)로 주입.
//   예) SOLAPI_TEMPLATE_IDS={"pickup_accepted":"KA01TP...","arrived":"KA01TP...",...}
// 새 타입은 공용 JSON env를 건드리지 않도록 코드 기본값을 둔다(templateId는 비밀값 아님, env에 같은 키가 있으면 env 우선).
export const DEFAULT_SOLAPI_TEMPLATE_IDS = {
  // 수북 일성월심 앱안내 v1 — 2026-11-18 솔라피 등록·카카오 검수 요청(ALIMTALK_TEMPLATES.md "일성월심 앱 이용 안내" 절)
  app_guide: "KA01TP2611181230053048VITk7GCMRa",
};

export function getSolapiTemplateId(notificationType, env = process.env) {
  let map = {};
  try {
    map = JSON.parse(env.SOLAPI_TEMPLATE_IDS || "{}") || {};
  } catch {
    map = {};
  }
  return map[notificationType] || DEFAULT_SOLAPI_TEMPLATE_IDS[notificationType] || "";
}
