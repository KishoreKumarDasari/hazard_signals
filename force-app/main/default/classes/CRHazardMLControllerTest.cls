/**
 * @description Tests for CRHazardMLController (record page + list-view ML invocation).
 */
@isTest
private class CRHazardMLControllerTest {

    private static Hazard_Signal__c createSignal() {
        Hazard_Signal__c s = new Hazard_Signal__c(
            Source_Record_Id__c = 'ML-ctrl-1',
            Source_System__c = 'ML_Model',
            Event_Type__c = CRDisasterConstants.EVENT_GLACIAL_LAKE,
            Risk_Level__c = CRDisasterConstants.RISK_CRITICAL,
            Risk_Score__c = 80,
            Alert_Phase__c = CRDisasterConstants.PHASE_PRECURSOR,
            Lead_Time_Hours__c = 72,
            Location_Name__c = 'Imja Tsho',
            Latitude__c = 27.9,
            Longitude__c = 86.9
        );
        insert s;
        insert new Hazard_Media__c(Hazard_Signal__c = s.Id, Source_Ref_Id__c = 'ML-ctrl-1-img', Media_URL__c = 'https://img/1.png', Media_Type__c = 'Satellite', Sort_Order__c = 0);
        return s;
    }

    @isTest
    static void testGetHazard() {
        Hazard_Signal__c s = createSignal();
        Test.startTest();
        CRHazardMLController.HazardView view = CRHazardMLController.getHazard(s.Id);
        Test.stopTest();
        System.assertEquals(s.Id, view.signal.Id);
        System.assertEquals(1, view.media.size());
    }

    @isTest
    static void testRunMlPrediction() {
        Hazard_Signal__c s = createSignal();
        Test.setMock(HttpCalloutMock.class, new CRHazardCalloutMock());
        Test.startTest();
        String output = CRHazardMLController.runMlPrediction(s.Id);
        Test.stopTest();
        System.assert(output.contains('Critical'), 'ML output should be returned');
        Hazard_Signal__c updated = [SELECT ML_Output__c, ML_Last_Run__c FROM Hazard_Signal__c WHERE Id = :s.Id];
        System.assertNotEquals(null, updated.ML_Last_Run__c);
    }

    @isTest
    static void testRunMlForRecords() {
        Hazard_Signal__c s = createSignal();
        Test.setMock(HttpCalloutMock.class, new CRHazardCalloutMock());
        Test.startTest();
        Integer count = CRHazardMLController.runMlForRecords(new List<Id>{ s.Id });
        Test.stopTest();
        System.assertEquals(1, count);
    }

    @isTest
    static void testRunMlForRecordsEmpty() {
        System.assertEquals(0, CRHazardMLController.runMlForRecords(new List<Id>()));
    }
}