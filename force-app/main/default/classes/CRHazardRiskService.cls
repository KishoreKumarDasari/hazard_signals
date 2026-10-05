/**
 * @description Scores parsed hazard signals, upserts them (idempotent on Source_Record_Id__c),
 *              upserts related media, and dispatches responder notifications for Critical/High risk.
 *              All callouts happen in CRHazardIngestQueueable; this class is DML + notifications only.
 */
public without sharing class CRHazardRiskService {

    /**
     * @description In-memory representation of one parsed signal plus its media, produced by the ingest parsers.
     */
    public class ParsedHazard {
        public Hazard_Signal__c signal;
        public List<Hazard_Media__c> media;
        public ParsedHazard() {
            this.signal = new Hazard_Signal__c();
            this.media = new List<Hazard_Media__c>();
        }
    }

    /**
     * @description Applies risk-level thresholds, upserts signals and media, then notifies for Critical/High.
     * @param hazards Parsed hazards collected from all sources.
     * @param criticalByExtId Critical score threshold keyed by Source_Record_Id__c prefix (source key).
     * @param highByExtId High score threshold keyed by source key.
     */
    public static void process(List<ParsedHazard> hazards, Map<String, Decimal> criticalBySource, Map<String, Decimal> highBySource) {
        if (hazards == null || hazards.isEmpty()) {
            return;
        }

        List<Hazard_Signal__c> signalsToUpsert = new List<Hazard_Signal__c>();
        for (ParsedHazard ph : hazards) {
            applyRiskLevel(ph.signal, criticalBySource, highBySource);
            if (ph.signal.Detected_At__c == null) {
                ph.signal.Detected_At__c = System.now();
            }
            signalsToUpsert.add(ph.signal);
        }

        Database.upsert(signalsToUpsert, Hazard_Signal__c.Source_Record_Id__c, false);

        upsertMedia(hazards);
        notifyHighRisk(signalsToUpsert);
    }

    private static void applyRiskLevel(Hazard_Signal__c signal, Map<String, Decimal> criticalBySource, Map<String, Decimal> highBySource) {
        Decimal score = signal.Risk_Score__c == null ? 0 : signal.Risk_Score__c;
        Decimal critical = safeThreshold(criticalBySource, signal.Source_System__c, 75);
        Decimal high = safeThreshold(highBySource, signal.Source_System__c, 50);

        if (score >= critical) {
            signal.Risk_Level__c = CRDisasterConstants.RISK_CRITICAL;
        } else if (score >= high) {
            signal.Risk_Level__c = CRDisasterConstants.RISK_HIGH;
        } else if (score >= CRDisasterConstants.MEDIUM_THRESHOLD) {
            signal.Risk_Level__c = CRDisasterConstants.RISK_MEDIUM;
        } else {
            signal.Risk_Level__c = CRDisasterConstants.RISK_LOW;
        }
    }

    private static Decimal safeThreshold(Map<String, Decimal> thresholds, String key, Decimal fallback) {
        if (key != null && thresholds != null && thresholds.containsKey(key) && thresholds.get(key) != null) {
            return thresholds.get(key);
        }
        return fallback;
    }

    private static void upsertMedia(List<ParsedHazard> hazards) {
        List<Hazard_Media__c> mediaToUpsert = new List<Hazard_Media__c>();
        for (ParsedHazard ph : hazards) {
            if (ph.signal.Id == null || ph.media == null) {
                continue;
            }
            for (Hazard_Media__c m : ph.media) {
                m.Hazard_Signal__c = ph.signal.Id;
                mediaToUpsert.add(m);
            }
        }
        if (!mediaToUpsert.isEmpty()) {
            Database.upsert(mediaToUpsert, Hazard_Media__c.Source_Ref_Id__c, false);
        }
    }

    private static void notifyHighRisk(List<Hazard_Signal__c> signals) {
        Set<String> targets = getRecipientIds();
        if (targets.isEmpty()) {
            return;
        }

        List<Hazard_Signal__c> toMark = new List<Hazard_Signal__c>();
        Messaging.CustomNotification notification = new Messaging.CustomNotification();
        Id typeId = getNotificationTypeId();
        if (typeId == null) {
            return;
        }
        notification.setNotificationTypeId(typeId);

        for (Hazard_Signal__c s : signals) {
            Boolean isHighRisk = CRDisasterConstants.RISK_CRITICAL.equals(s.Risk_Level__c)
                || CRDisasterConstants.RISK_HIGH.equals(s.Risk_Level__c);
            if (!isHighRisk || s.Notified__c == true || s.Id == null) {
                continue;
            }
            notification.setTitle(buildTitle(s));
            notification.setBody(buildBody(s));
            notification.setTargetId(s.Id);
            try {
                notification.send(targets);
            } catch (Exception ex) {
                // Notification failures must not block ingest; the record is still flagged.
                System.debug(LoggingLevel.WARN, 'Hazard notification failed: ' + ex.getMessage());
            }
            s.Notified__c = true;
            toMark.add(s);
        }

        if (!toMark.isEmpty()) {
            Database.update(toMark, false);
        }
    }

    private static String buildTitle(Hazard_Signal__c s) {
        return s.Risk_Level__c + ' flash-flood risk: ' + (s.Location_Name__c == null ? 'Unknown location' : s.Location_Name__c);
    }

    private static String buildBody(Hazard_Signal__c s) {
        String phaseMsg = CRDisasterConstants.PHASE_PRECURSOR.equals(s.Alert_Phase__c)
            ? 'Evacuation window ~' + (s.Lead_Time_Hours__c == null ? '?' : String.valueOf(s.Lead_Time_Hours__c)) + 'h.'
            : 'Event in progress — deploy response.';
        return s.Event_Type__c + ' | ' + s.Alert_Phase__c + ' | ' + phaseMsg;
    }

    private static Id getNotificationTypeId() {
        List<CustomNotificationType> types = [
            SELECT Id FROM CustomNotificationType
            WHERE DeveloperName = :CRDisasterConstants.NOTIFICATION_TYPE
            LIMIT 1
        ];
        return types.isEmpty() ? null : types[0].Id;
    }

    private static Set<String> getRecipientIds() {
        Set<String> ids = new Set<String>();
        List<Group> groups = [
            SELECT Id FROM Group
            WHERE DeveloperName = :CRDisasterConstants.RESPONSE_GROUP AND Type = 'Regular'
            LIMIT 1
        ];
        if (!groups.isEmpty()) {
            ids.add(groups[0].Id);
        } else {
            ids.add(UserInfo.getUserId());
        }
        return ids;
    }
}