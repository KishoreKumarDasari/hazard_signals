/**
 * @description Test HttpCalloutMock that returns canned JSON for USGS, GDACS and the ML model
 *              based on the requested endpoint.
 */
@isTest
public class CRHazardCalloutMock implements HttpCalloutMock {

    public HttpResponse respond(HttpRequest req) {
        HttpResponse res = new HttpResponse();
        res.setHeader('Content-Type', 'application/json');
        res.setStatusCode(200);
        String endpoint = req.getEndpoint().toLowerCase();

        if (endpoint.contains('earthquake')) {
            res.setBody(usgsBody());
        } else if (endpoint.contains('gdacs')) {
            res.setBody(gdacsBody());
        } else if (endpoint.contains('predict')) {
            res.setBody('{"risk":"Critical","probability":0.87,"message":"GLOF likely within 72h","image_url":"https://img/pred.png"}');
        } else if (endpoint.contains('precursor')) {
            res.setBody(mlPrecursorBody());
        } else {
            res.setBody('{}');
        }
        return res;
    }

    public static String usgsBody() {
        return '{"features":[{"id":"us1","properties":{"mag":6.2,"place":"Near Nepal","time":1690000000000,'
            + '"url":"https://usgs/us1","alert":"orange","sig":600},"geometry":{"coordinates":[85.0,28.0,10]}}]}';
    }

    public static String gdacsBody() {
        return '{"features":[{"properties":{"eventtype":"FL","alertlevel":"Red","name":"Nepal Flood","country":"Nepal",'
            + '"eventid":123,"episodeid":1,"fromdate":1690000000000,"icon":"https://gdacs/icon.png",'
            + '"url":{"report":"https://gdacs/report"}},"geometry":{"coordinates":[85.0,28.0]}}]}';
    }

    public static String mlPrecursorBody() {
        return '{"signals":[{"id":"lake1","lake":"Imja Tsho","region":"Nepal-Tibet Himalaya","continent":"Asia",'
            + '"country":"Nepal","lat":27.9,"lon":86.9,"observed_area_km2":1.5,"baseline_area_km2":1.0,'
            + '"risk_score":80,"lead_time_hours":72,"source_url":"https://icimod/imja",'
            + '"images":[{"url":"https://img/1.png","caption":"Sentinel-2","type":"Satellite"}]}]}';
    }
}