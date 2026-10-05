/**
 * @description LWC controller for the Hazard ML panel. Reads a Hazard Signal, sends its data to
 *              the external Gradio ML model, caches the result on the record, and returns media.
 *              Supports single-record (record page) and bulk (list-view) invocation.
 */
public with sharing class CRHazardMLController {

    private static final String ML_NAMED_CREDENTIAL = 'Disaster_ML_API';
    private static final String ML_PREDICT_PATH = '/api/predict';

    /**
     * @description Wrapper returned to the LWC with the signal, its media and the ML output.
     */
    public class HazardView {
        @AuraEnabled public Hazard_Signal__c signal;
        @AuraEnabled public List<Hazard_Media__c> media;
        @AuraEnabled public String mlOutput;
    }

    /**
     * @description Loads a hazard signal and its media for display in the LWC.
     * @param recordId Hazard_Signal__c Id.
     * @return HazardView with signal + media (mlOutput = cached value).
     */
    @AuraEnabled(cacheable=true)
    public static HazardView getHazard(Id recordId) {
        HazardView view = new HazardView();
        view.signal = querySignal(recordId);
        view.media = queryMedia(recordId);
        view.mlOutput = view.signal.ML_Output__c;
        return view;
    }

    /**
     * @description Sends the record's data to the external ML model and caches the response.
     * @param recordId Hazard_Signal__c Id.
     * @return The ML model output text.
     */
    @AuraEnabled
    public static String runMlPrediction(Id recordId) {
        Hazard_Signal__c signal = querySignal(recordId);
        String output = callMlModel(signal);
        cacheOutput(recordId, output);
        return output;
    }

    /**
     * @description Runs the ML model for multiple selected records (list-view bulk action).
     * @param recordIds Set of Hazard_Signal__c Ids.
     * @return Number of records successfully processed.
     */
    @AuraEnabled
    public static Integer runMlForRecords(List<Id> recordIds) {
        if (recordIds == null || recordIds.isEmpty()) {
            return 0;
        }
        List<Hazard_Signal__c> signals = [
            SELECT Id, Name, Event_Type__c, Risk_Level__c, Risk_Score__c, Alert_Phase__c,
                   Lead_Time_Hours__c, Location_Name__c, Region__c, Country__c, Latitude__c,
                   Longitude__c, Observed_Value__c, Baseline_Value__c
            FROM Hazard_Signal__c
            WHERE Id IN :recordIds
            WITH USER_MODE
        ];
        List<Hazard_Signal__c> toUpdate = new List<Hazard_Signal__c>();
        for (Hazard_Signal__c s : signals) {
            String output = callMlModel(s);
            toUpdate.add(new Hazard_Signal__c(Id = s.Id, ML_Output__c = output, ML_Last_Run__c = System.now()));
        }
        if (!toUpdate.isEmpty() && Schema.sObjectType.Hazard_Signal__c.isUpdateable()) {
            update as user toUpdate;
        }
        return toUpdate.size();
    }

    private static Hazard_Signal__c querySignal(Id recordId) {
        return [
            SELECT Id, Name, Source_System__c, Event_Type__c, Risk_Level__c, Risk_Score__c,
                   Alert_Phase__c, Lead_Time_Hours__c, Location_Name__c, Region__c, Continent__c,
                   Country__c, Latitude__c, Longitude__c, Observed_Value__c, Baseline_Value__c,
                   Change_Percent__c, Primary_Source_URL__c, ML_Output__c, ML_Last_Run__c,
                   Predicted_Impact_Window__c, Observation_Time__c
            FROM Hazard_Signal__c
            WHERE Id = :recordId
            WITH USER_MODE
            LIMIT 1
        ];
    }

    private static List<Hazard_Media__c> queryMedia(Id recordId) {
        return [
            SELECT Id, Media_URL__c, Media_Type__c, Caption__c, Sort_Order__c
            FROM Hazard_Media__c
            WHERE Hazard_Signal__c = :recordId
            WITH USER_MODE
            ORDER BY Sort_Order__c NULLS LAST, CreatedDate ASC
        ];
    }

    private static String callMlModel(Hazard_Signal__c signal) {
        Map<String, Object> payload = new Map<String, Object>{
            'id' => signal.Id,
            'event_type' => signal.Event_Type__c,
            'risk_level' => signal.Risk_Level__c,
            'risk_score' => signal.Risk_Score__c,
            'alert_phase' => signal.Alert_Phase__c,
            'lead_time_hours' => signal.Lead_Time_Hours__c,
            'location' => signal.Location_Name__c,
            'region' => signal.Region__c,
            'country' => signal.Country__c,
            'latitude' => signal.Latitude__c,
            'longitude' => signal.Longitude__c,
            'observed_value' => signal.Observed_Value__c,
            'baseline_value' => signal.Baseline_Value__c
        };

        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:' + ML_NAMED_CREDENTIAL + ML_PREDICT_PATH);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Accept', 'application/json');
        req.setTimeout(120000);
        req.setBody(JSON.serialize(payload));

        try {
            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() >= 200 && res.getStatusCode() < 300) {
                return res.getBody();
            }
            return 'ML model error (HTTP ' + res.getStatusCode() + '): ' + res.getBody();
        } catch (Exception ex) {
            throw new AuraHandledException('ML callout failed: ' + ex.getMessage());
        }
    }

    private static void cacheOutput(Id recordId, String output) {
        if (!Schema.sObjectType.Hazard_Signal__c.isUpdateable()) {
            return;
        }
        Hazard_Signal__c toUpdate = new Hazard_Signal__c(
            Id = recordId,
            ML_Output__c = output,
            ML_Last_Run__c = System.now()
        );
        update as user toUpdate;
    }
}