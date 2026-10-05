/**
 * @description Tests for the hazard ingest pipeline: scoring, parsing, callouts, upsert and notifications.
 */
@isTest
private class CRHazardIngestTest {

    private static Hazard_Region__mdt nepalRegion() {
        return new Hazard_Region__mdt(
            Region_Name__c = 'Nepal-Tibet Himalaya',
            Continent__c = 'Asia',
            Country__c = 'Nepal',
            Min_Latitude__c = 26, Max_Latitude__c = 31,
            Min_Longitude__c = 80, Max_Longitude__c = 89,
            Min_Magnitude__c = 4.5
        );
    }

    @isTest
    static void testScoreUsgs() {
        System.assertEquals(100, CRHazardIngestQueueable.scoreUsgs(7.5, 'red'), 'Major quake + red capped at 100');
        System.assert(CRHazardIngestQueueable.scoreUsgs(6.2, 'orange') >= 55, 'M6 should be High+');
        System.assertEquals(30, CRHazardIngestQueueable.scoreUsgs(3.0, null), 'Small quake low score');
    }

    @isTest
    static void testScoreGdacs() {
        System.assertEquals(85, CRHazardIngestQueueable.scoreGdacs('Red'));
        System.assertEquals(60, CRHazardIngestQueueable.scoreGdacs('Orange'));
        System.assertEquals(30, CRHazardIngestQueueable.scoreGdacs('Green'));
        System.assertEquals(20, CRHazardIngestQueueable.scoreGdacs(null));
    }

    @isTest
    static void testParseUsgs() {
        CRHazardIngestQueueable q = new CRHazardIngestQueueable();
        List<CRHazardRiskService.ParsedHazard> parsed = q.parseUsgs(CRHazardCalloutMock.usgsBody(), nepalRegion());
        System.assertEquals(1, parsed.size());
        Hazard_Signal__c s = parsed[0].signal;
        System.assertEquals('USGS-us1', s.Source_Record_Id__c);
        System.assertEquals(28.0, s.Latitude__c);
        System.assertEquals('Nepal-Tibet Himalaya', s.Region__c);
        System.assertEquals(CRDisasterConstants.PHASE_IMPACT, s.Alert_Phase__c);
    }

    @isTest
    static void testParseGdacs() {
        CRHazardIngestQueueable q = new CRHazardIngestQueueable();
        List<CRHazardRiskService.ParsedHazard> parsed = q.parseGdacs(CRHazardCalloutMock.gdacsBody(), new List<Hazard_Region__mdt>{ nepalRegion() });
        System.assertEquals(1, parsed.size());
        System.assertEquals(CRDisasterConstants.EVENT_FLOOD, parsed[0].signal.Event_Type__c);
        System.assert(parsed[0].media.size() >= 1, 'Should capture GDACS media');
    }

    @isTest
    static void testParseMl() {
        CRHazardIngestQueueable q = new CRHazardIngestQueueable();
        List<CRHazardRiskService.ParsedHazard> parsed = q.parseMl(CRHazardCalloutMock.mlPrecursorBody());
        System.assertEquals(1, parsed.size());
        Hazard_Signal__c s = parsed[0].signal;
        System.assertEquals(CRDisasterConstants.PHASE_PRECURSOR, s.Alert_Phase__c);
        System.assertEquals(72, s.Lead_Time_Hours__c);
        System.assertNotEquals(null, s.Predicted_Impact_Window__c);
        System.assert(parsed[0].media.size() == 1, 'Should capture ML image');
    }

    @isTest
    static void testServiceProcessAndNotify() {
        CRHazardRiskService.ParsedHazard ph = new CRHazardRiskService.ParsedHazard();
        ph.signal.Source_System__c = CRDisasterConstants.SOURCE_USGS;
        ph.signal.Source_Record_Id__c = 'USGS-testA';
        ph.signal.Event_Type__c = CRDisasterConstants.EVENT_EARTHQUAKE;
        ph.signal.Risk_Score__c = 90;
        ph.signal.Alert_Phase__c = CRDisasterConstants.PHASE_IMPACT;
        ph.signal.Location_Name__c = 'Test Place';
        ph.media.add(new Hazard_Media__c(Source_Ref_Id__c = 'USGS-testA-img', Media_URL__c = 'https://img/a.png', Media_Type__c = 'Satellite'));

        Map<String, Decimal> crit = new Map<String, Decimal>{ CRDisasterConstants.SOURCE_USGS => 75 };
        Map<String, Decimal> high = new Map<String, Decimal>{ CRDisasterConstants.SOURCE_USGS => 50 };

        Test.startTest();
        CRHazardRiskService.process(new List<CRHazardRiskService.ParsedHazard>{ ph }, crit, high);
        Test.stopTest();

        Hazard_Signal__c saved = [SELECT Risk_Level__c, Notified__c FROM Hazard_Signal__c WHERE Source_Record_Id__c = 'USGS-testA'];
        System.assertEquals(CRDisasterConstants.RISK_CRITICAL, saved.Risk_Level__c);
        System.assertEquals(true, saved.Notified__c, 'High-risk record should be marked notified');
        System.assertEquals(1, [SELECT COUNT() FROM Hazard_Media__c]);
    }

    @isTest
    static void testEndToEndCallouts() {
        Test.setMock(HttpCalloutMock.class, new CRHazardCalloutMock());
        Test.startTest();
        new CRHazardIngestQueueable().execute(null);
        Test.stopTest();
        System.assert([SELECT COUNT() FROM Hazard_Signal__c] > 0, 'Ingest should create signals');
    }

    @isTest
    static void testSchedulable() {
        Test.setMock(HttpCalloutMock.class, new CRHazardCalloutMock());
        Test.startTest();
        String jobId = System.schedule('Hazard Ingest Test', '0 0 0 15 3 ? 2042', new CRHazardIngestSchedulable());
        Test.stopTest();
        System.assertNotEquals(null, jobId);
    }
}